require "base64"
require "fastlane/action"
require "json"
require "jwt"
require "net/http"
require "openssl"
require "uri"

module Fastlane
  module Actions
    class SyncAccessibilityDeclarationsAction < Action
      API_ROOT = "https://api.appstoreconnect.apple.com"
      FEATURE_KEYS = %w[
        supportsAudioDescriptions
        supportsCaptions
        supportsDarkInterface
        supportsDifferentiateWithoutColorAlone
        supportsLargerText
        supportsReducedMotion
        supportsSufficientContrast
        supportsVoiceControl
        supportsVoiceover
      ].freeze

      def self.run(params)
        config = JSON.parse(File.read(params[:config_path]))
        token = make_token(params)
        app_id = find_app_id(token, params[:app_identifier])

        sync_accessibility_url(token, app_id, config["accessibilityUrl"]) if config.key?("accessibilityUrl")
        existing = list_declarations(token, app_id)

        config.fetch("declarations").each do |declaration|
          device_family = declaration.fetch("deviceFamily")
          attributes = declaration_attributes(declaration)
          current = existing_for_device(existing, device_family)

          if current
            update_declaration(token, current.fetch("id"), attributes)
            UI.success("Updated #{device_family} accessibility declaration")
          else
            create_declaration(token, app_id, attributes)
            UI.success("Created #{device_family} accessibility declaration")
          end
        end
      end

      def self.make_token(params)
        key_content = params[:key_content].to_s
        key_content = Base64.decode64(key_content) if params[:is_key_content_base64]
        key_content = key_content.gsub("\\n", "\n")
        private_key = OpenSSL::PKey::EC.new(key_content)
        payload = {
          iss: params[:issuer_id],
          exp: Time.now.to_i + 20 * 60,
          aud: "appstoreconnect-v1"
        }
        headers = {
          kid: params[:key_id],
          typ: "JWT"
        }
        JWT.encode(payload, private_key, "ES256", headers)
      end

      def self.find_app_id(token, bundle_id)
        response = request(token, :get, "/v1/apps", query: { "filter[bundleId]" => bundle_id, "limit" => "1" })
        app = response.fetch("data").first
        UI.user_error!("Could not find App Store Connect app for bundle id #{bundle_id}") unless app
        app.fetch("id")
      end

      def self.list_declarations(token, app_id)
        response = request(
          token,
          :get,
          "/v1/apps/#{app_id}/accessibilityDeclarations",
          query: { "limit" => "200" }
        )
        response.fetch("data", [])
      end

      def self.existing_for_device(declarations, device_family)
        declarations
          .reject { |item| item.dig("attributes", "state") == "REPLACED" }
          .select { |item| item.dig("attributes", "deviceFamily") == device_family }
          .sort_by { |item| item.dig("attributes", "state") == "DRAFT" ? 0 : 1 }
          .first
      end

      def self.declaration_attributes(declaration)
        attributes = { "deviceFamily" => declaration.fetch("deviceFamily") }
        FEATURE_KEYS.each do |key|
          attributes[key] = declaration.fetch(key, false)
        end
        attributes
      end

      def self.create_declaration(token, app_id, attributes)
        request(
          token,
          :post,
          "/v1/accessibilityDeclarations",
          body: {
            data: {
              type: "accessibilityDeclarations",
              attributes: attributes,
              relationships: {
                app: {
                  data: {
                    type: "apps",
                    id: app_id
                  }
                }
              }
            }
          }
        )
      end

      def self.update_declaration(token, declaration_id, attributes)
        request(
          token,
          :patch,
          "/v1/accessibilityDeclarations/#{declaration_id}",
          body: {
            data: {
              type: "accessibilityDeclarations",
              id: declaration_id,
              attributes: attributes
            }
          }
        )
      end

      def self.sync_accessibility_url(token, app_id, accessibility_url)
        request(
          token,
          :patch,
          "/v1/apps/#{app_id}",
          body: {
            data: {
              type: "apps",
              id: app_id,
              attributes: {
                accessibilityUrl: accessibility_url
              }
            }
          }
        )
        UI.success("Updated accessibility URL")
      end

      def self.request(token, method, path, query: {}, body: nil)
        uri = URI("#{API_ROOT}#{path}")
        uri.query = URI.encode_www_form(query) if query.any?

        klass = {
          get: Net::HTTP::Get,
          post: Net::HTTP::Post,
          patch: Net::HTTP::Patch
        }.fetch(method)

        request = klass.new(uri)
        request["Authorization"] = "Bearer #{token}"
        request["Content-Type"] = "application/json"
        request["Accept"] = "application/json"
        request.body = JSON.generate(body) if body

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
          http.request(request)
        end

        parsed = response.body.to_s.empty? ? {} : JSON.parse(response.body)
        return parsed if response.code.to_i.between?(200, 299)

        detail = parsed.fetch("errors", []).map { |error| error["detail"] || error["title"] }.compact.join(" ")
        UI.user_error!("App Store Connect accessibility API request failed: #{response.code} #{detail}")
      end

      def self.description
        "Sync App Store Accessibility Nutrition Label declarations"
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(key: :app_identifier,
                                       description: "The app bundle identifier",
                                       optional: false),
          FastlaneCore::ConfigItem.new(key: :key_id,
                                       description: "App Store Connect API key ID",
                                       optional: false,
                                       sensitive: true),
          FastlaneCore::ConfigItem.new(key: :issuer_id,
                                       description: "App Store Connect API issuer ID",
                                       optional: false,
                                       sensitive: true),
          FastlaneCore::ConfigItem.new(key: :key_content,
                                       description: "App Store Connect API private key content",
                                       optional: false,
                                       sensitive: true),
          FastlaneCore::ConfigItem.new(key: :is_key_content_base64,
                                       description: "Whether key_content is base64 encoded",
                                       optional: true,
                                       type: Boolean,
                                       default_value: false),
          FastlaneCore::ConfigItem.new(key: :config_path,
                                       description: "Path to accessibility declarations JSON",
                                       optional: false,
                                       verify_block: proc do |value|
                                         UI.user_error!("Could not find accessibility config at #{value}") unless File.exist?(value)
                                       end)
        ]
      end

      def self.authors
        ["PicStrip"]
      end

      def self.is_supported?(platform)
        platform == :ios
      end
    end
  end
end
