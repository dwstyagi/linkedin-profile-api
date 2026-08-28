require "test_helper"

module LinkedIn
  class ProfileUrlTest < ActiveSupport::TestCase
    test "extracts the slug from the URLs people actually paste" do
      {
        "https://www.linkedin.com/in/ada-lovelace/" => "ada-lovelace",
        "https://www.linkedin.com/in/ada-lovelace?trk=nav_feed" => "ada-lovelace",
        "http://linkedin.com/in/ada-lovelace" => "ada-lovelace",
        "linkedin.com/in/ada-lovelace" => "ada-lovelace",
        "https://in.linkedin.com/in/ada-lovelace/" => "ada-lovelace",
        "  https://www.linkedin.com/in/ada-lovelace/  " => "ada-lovelace"
      }.each do |input, expected|
        assert_equal expected, ProfileUrl.parse(input).public_identifier, "for #{input}"
      end
    end

    test "decodes percent-encoded slugs" do
      parsed = ProfileUrl.parse("https://www.linkedin.com/in/%C3%A5sa-berg")

      assert_equal "åsa-berg", parsed.public_identifier
    end

    test "canonicalises so tracking parameters do not fragment the cache" do
      tracked = ProfileUrl.parse("https://in.linkedin.com/in/ada-lovelace?trk=x")

      assert_equal "https://www.linkedin.com/in/ada-lovelace", tracked.canonical_url
    end

    test "rejects anything that is not a member profile" do
      [
        nil,
        "",
        "not a url at all",
        "https://example.com/in/ada-lovelace",
        "https://notlinkedin.com/in/ada-lovelace",
        "https://www.linkedin.com/company/microsoft",
        "https://www.linkedin.com/school/mit",
        "https://www.linkedin.com/feed/"
      ].each do |input|
        assert_raises(InvalidProfileUrl, "expected #{input.inspect} to be rejected") do
          ProfileUrl.parse(input)
        end
      end
    end
  end
end
