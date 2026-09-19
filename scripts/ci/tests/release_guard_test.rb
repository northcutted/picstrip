require "minitest/autorun"
require_relative "../../../fastlane/lib/release_guard"

class ReleaseGuardTest < Minitest::Test
  def manifest
    {"schema_version" => 2, "version" => "1.7.0", "build_number" => "100.1", "app_store_build_id" => "verified-id"}
  end

  def client(build_id: "verified-id", state: "VALID", number: "100.1")
    lambda do |path, query|
      case path
      when "/v1/apps" then {"data" => [{"id" => "app"}]}
      when "/v1/apps/app/appStoreVersions" then {"data" => [{"id" => "version", "attributes" => {"versionString" => "1.7.0"}}]}
      when "/v1/appStoreVersions/version/build"
        {"data" => {"id" => build_id, "attributes" => {"version" => number, "processingState" => state}}}
      else raise "Unexpected API request: #{path}"
      end
    end
  end

  def test_requires_exact_selected_build
    ReleaseGuard.new(manifest, client: client).verify_selected_build!
    [client(build_id: "substituted-id"), client(state: "PROCESSING"), client(number: "101.1")].each do |api|
      assert_raises(RuntimeError) { ReleaseGuard.new(manifest, client: api).verify_selected_build! }
    end
  end

  def test_tracks_metadata_edits_without_silently_rewriting_them
    before = {"build" => "verified-id", "metadata" => {"description" => "Original"}}
    after = {"build" => "verified-id", "metadata" => {"description" => "Edited in Connect"}}
    assert_equal [{"path" => "/metadata/description", "before" => "Original", "after" => "Edited in Connect"}], ReleaseGuard.diff(before, after)
    assert_equal "Original", before["metadata"]["description"]
  end

  def test_failed_processing_is_terminal
    guard = ReleaseGuard.new(manifest, client: client)
    def guard.find_build; {"attributes" => {"processingState" => "INVALID"}}; end
    assert_raises(RuntimeError) { guard.wait_for_processing(timeout: 1, interval: 0) }
  end

  def test_processing_wait_is_bounded
    guard = ReleaseGuard.new(manifest, client: client)
    def guard.find_build; nil; end
    assert_raises(RuntimeError) { guard.wait_for_processing(timeout: 0, interval: 0) }
  end
end
