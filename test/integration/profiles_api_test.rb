require "test_helper"

class ProfilesApiTest < ActionDispatch::IntegrationTest
  ENDPOINT = "/api/v1/profile".freeze

  setup do
    @headers = { "X-API-Key" => Rails.application.config.x.api_key }
  end

  test "rejects requests without a valid API key" do
    get ENDPOINT, params: { url: profile_url }

    assert_response :unauthorized
    assert_equal "unauthorized", error_code

    get ENDPOINT, params: { url: profile_url }, headers: { "X-API-Key" => "wrong" }

    assert_response :unauthorized
  end

  test "rejects a non-profile URL before touching the network" do
    stub_fetcher_raising(StandardError.new("the network must not be used")) do
      get ENDPOINT, params: { url: "https://www.linkedin.com/company/microsoft" }, headers: @headers
    end

    assert_response :unprocessable_content
    assert_equal "invalid_url", error_code
  end

  test "serves a fresh cache entry without calling LinkedIn" do
    CachedProfile.store!(
      public_identifier: "ada-lovelace",
      profile_url: profile_url,
      data: { "full_name" => "Ada Lovelace" },
      raw_payload: { "profile" => {} }
    )

    stub_fetcher_raising(StandardError.new("the network must not be used")) do
      get ENDPOINT, params: { url: "#{profile_url}?trk=share" }, headers: @headers
    end

    assert_response :success
    assert_equal "Ada Lovelace", body.dig("data", "full_name")
    assert body.dig("meta", "cached")
  end

  test "fetches, normalizes and caches on a miss" do
    payload = JSON.parse(file_fixture("dash_profile.json").read)

    stub_fetcher_returning(payload) do
      assert_difference "CachedProfile.count", 1 do
        get ENDPOINT, params: { url: profile_url }, headers: @headers
      end
    end

    assert_response :success
    assert_equal "Ada Lovelace", body.dig("data", "full_name")
    assert_not body.dig("meta", "cached")
    assert_equal "linkedin_voyager", body.dig("meta", "source")
  end

  test "refresh=true bypasses a fresh cache entry" do
    CachedProfile.store!(
      public_identifier: "ada-lovelace",
      profile_url: profile_url,
      data: { "full_name" => "Stale Name" },
      raw_payload: {}
    )
    payload = JSON.parse(file_fixture("dash_profile.json").read)

    stub_fetcher_returning(payload) do
      get ENDPOINT, params: { url: profile_url, refresh: "true" }, headers: @headers
    end

    assert_response :success
    assert_equal "Ada Lovelace", body.dig("data", "full_name")
    assert_not body.dig("meta", "cached")
  end

  test "maps upstream failures onto distinct status codes" do
    {
      LinkedIn::SessionExpired.new("cookie died") => [ 503, "linkedin_session_expired" ],
      LinkedIn::ProfileNotFound.new("no such member") => [ 404, "profile_not_found" ],
      LinkedIn::RateLimited.new("slow down") => [ 429, "rate_limited" ],
      LinkedIn::UpstreamError.new("bad gateway") => [ 502, "upstream_error" ]
    }.each do |error, (status, code)|
      stub_fetcher_raising(error) do
        get ENDPOINT, params: { url: profile_url }, headers: @headers
      end

      assert_equal status, response.status, "for #{error.class}"
      assert_equal code, error_code
    end
  end

  private

  def profile_url = "https://www.linkedin.com/in/ada-lovelace"

  def body = JSON.parse(response.body)

  def error_code = body.dig("error", "code")

  # Replaces the fetcher entirely, so no client is constructed and no LinkedIn
  # session is needed to run the suite.
  def stub_fetcher_returning(payload, &block)
    with_fetcher(Struct.new(:payload) { def call = self.payload }.new(payload), &block)
  end

  def stub_fetcher_raising(error, &block)
    with_fetcher(Struct.new(:error) { def call = raise(self.error) }.new(error), &block)
  end
end
