require "json"
require "digest"
require "fileutils"
require "jwt"
require "net/http"
require "openssl"
require "uri"

# Read-only App Store API checks. No method in this class changes Apple state.
class ReleaseGuard
  ROOT = "https://api.appstoreconnect.apple.com".freeze
  BUNDLE_ID = "com.northcutt.PicStrip".freeze
  SUBMITTED_STATES = %w[WAITING_FOR_REVIEW IN_REVIEW ACCEPTED PENDING_APPLE_RELEASE PENDING_DEVELOPER_RELEASE PROCESSING_FOR_DISTRIBUTION READY_FOR_DISTRIBUTION READY_FOR_SALE].freeze

  def initialize(manifest, client: nil)
    @manifest = manifest
    @client = client
    raise "Release manifest schema must be 2" unless manifest["schema_version"] == 2
  end

  def get(path, query = {})
    return @client.call(path, query) if @client
    uri = URI(path.start_with?("https:") ? path : "#{ROOT}#{path}")
    raise "Unexpected App Store API host" unless uri.scheme == "https" && uri.host == "api.appstoreconnect.apple.com"
    uri.query = URI.encode_www_form(query) unless query.empty?
    4.times do |attempt|
      key = OpenSSL::PKey.read(ENV.fetch("APP_STORE_CONNECT_API_KEY_CONTENT").gsub('\\n', "\n"))
      token = JWT.encode({iss: ENV.fetch("APP_STORE_CONNECT_API_KEY_ISSUER_ID"), iat: Time.now.to_i - 10,
                          exp: Time.now.to_i + 600, aud: "appstoreconnect-v1"}, key, "ES256",
                         {kid: ENV.fetch("APP_STORE_CONNECT_API_KEY_ID"), typ: "JWT"})
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{token}"
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 60) { |http| http.request(request) }
      return JSON.parse(response.body) if response.is_a?(Net::HTTPSuccess)
      if (response.code == "429" || response.code.to_i >= 500) && attempt < 3
        sleep(2**attempt * 5)
      else
        # Do not include response bodies, credentials, or review contact information in logs.
        raise "App Store API #{uri.path}: HTTP #{response.code}"
      end
    end
  end

  def list(path, query = {})
    items = []
    loop do
      response = get(path, query)
      items.concat(response.fetch("data"))
      path = response.dig("links", "next")
      break unless path
      query = {}
    end
    items
  end

  def app_id
    @app_id ||= begin
      apps = list("/v1/apps", "filter[bundleId]" => BUNDLE_ID)
      raise "Expected one PicStrip app" unless apps.length == 1
      apps.first.fetch("id")
    end
  end

  def find_build
    response = get("/v1/builds", "filter[app]" => app_id,
                   "filter[preReleaseVersion.version]" => @manifest.fetch("version"),
                   "filter[version]" => @manifest.fetch("build_number"), "include" => "preReleaseVersion,app", "limit" => "200")
    builds = response.fetch("data")
    raise "Ambiguous App Store build" if builds.length > 1 || response.dig("links", "next")
    return nil if builds.empty?
    build = builds.first
    prerelease_id = build.dig("relationships", "preReleaseVersion", "data", "id")
    prerelease = response.fetch("included").find { |item| item["type"] == "preReleaseVersions" && item["id"] == prerelease_id }
    raise "Wrong build marketing version/platform" unless prerelease && prerelease.dig("attributes", "version") == @manifest["version"] && prerelease.dig("attributes", "platform") == "IOS"
    raise "Wrong build app/number" unless build.dig("relationships", "app", "data", "id") == app_id && build.dig("attributes", "version") == @manifest["build_number"]
    raise "Expired App Store build" if build.dig("attributes", "expired")
    build
  end

  def wait_for_processing(timeout: 3600, interval: 30)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      build = find_build
      state = build&.dig("attributes", "processingState")
      raise "App Store processing failed: #{state}" if %w[FAILED INVALID].include?(state)
      if state == "VALID"
        return @manifest.slice("source_sha", "version", "build_number", "ipa_sha256").merge(
          "app_store_build_id" => build.fetch("id"), "processing_state" => "VALID")
      end
      raise "Timed out waiting for exact App Store build" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep(interval)
    end
  end

  def version
    versions = list("/v1/apps/#{app_id}/appStoreVersions", "filter[versionString]" => @manifest.fetch("version"), "filter[platform]" => "IOS")
    raise "Expected one exact App Store version" unless versions.length == 1
    raise "Wrong App Store marketing version" unless versions.first.dig("attributes", "versionString") == @manifest.fetch("version")
    versions.first
  end

  def verify_selected_build!
    selected_version = version
    build = get("/v1/appStoreVersions/#{selected_version.fetch('id')}/build").fetch("data")
    raise "Selected build differs from verified release" unless build && build["id"] == @manifest.fetch("app_store_build_id") &&
      build.dig("attributes", "version") == @manifest.fetch("build_number") && build.dig("attributes", "processingState") == "VALID"
    selected_version
  end

  def snapshot
    selected_version = verify_selected_build!
    id = selected_version.fetch("id")
    localizations = list("/v1/appStoreVersions/#{id}/appStoreVersionLocalizations", "limit" => "200").map do |locale|
      sets = list("/v1/appStoreVersionLocalizations/#{locale.fetch('id')}/appScreenshotSets", "limit" => "200").map do |set|
        images = list("/v1/appScreenshotSets/#{set.fetch('id')}/appScreenshots", "limit" => "200")
        {"display_type" => set.dig("attributes", "screenshotDisplayType"),
         "images" => images.map { |image| image.fetch("attributes").slice("fileName", "fileSize", "sourceFileChecksum", "assetDeliveryState") }}
      end
      {"attributes" => locale.fetch("attributes").slice("locale", "description", "keywords", "marketingUrl", "supportUrl", "promotionalText", "whatsNew"),
       "screenshots" => sets.sort_by { |set| set["display_type"] }}
    end
    app_infos = list("/v1/apps/#{app_id}/appInfos", "limit" => "200").map do |info|
      translations = list("/v1/appInfos/#{info.fetch('id')}/appInfoLocalizations", "limit" => "200")
      {"attributes" => info.fetch("attributes"),
       "categories" => info.fetch("relationships", {}).slice("primaryCategory", "secondaryCategory"),
       "localizations" => translations.map { |t| t.fetch("attributes").slice("locale", "name", "subtitle", "privacyPolicyUrl", "privacyChoicesUrl") }.sort_by { |t| t["locale"] }}
    end
    # Review credentials and contact details deliberately never enter a public receipt.
    {"schema_version" => 1, "version" => @manifest["version"], "build_number" => @manifest["build_number"],
     "app_store_build_id" => @manifest["app_store_build_id"], "source_sha" => @manifest["source_sha"],
     "version_attributes" => selected_version.fetch("attributes").slice("versionString", "platform", "copyright", "releaseType", "appStoreState", "appVersionState"),
     "localizations" => localizations.sort_by { |locale| locale["attributes"]["locale"] },
     "app_information" => app_infos.sort_by { |i| i["attributes"].to_json }}
  end

  def self.diff(before, after, path = "")
    return [] if before == after
    if before.is_a?(Hash) && after.is_a?(Hash)
      return (before.keys | after.keys).sort.flat_map { |key| diff(before[key], after[key], "#{path}/#{key}") }
    end
    [{"path" => path, "before" => before, "after" => after}]
  end

  def self.save(path, value)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(value) + "\n")
  end
end
