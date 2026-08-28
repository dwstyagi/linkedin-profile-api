require "test_helper"

module LinkedIn
  class ProfileNormalizerTest < ActiveSupport::TestCase
    setup do
      payload = JSON.parse(file_fixture("dash_profile.json").read)
      @data = ProfileNormalizer.new(
        payload,
        public_identifier: "ada-lovelace",
        profile_url: "https://www.linkedin.com/in/ada-lovelace"
      ).call
    end

    test "maps the identity fields off the profile entity" do
      assert_equal "Ada Lovelace", @data["full_name"]
      assert_equal "Mathematician | Analytical Engine", @data["headline"]
      assert_equal "Wrote the first algorithm intended for a machine.", @data["about"]
      assert_equal "99887766", @data["member_id"]
      assert_equal "ada-lovelace", @data["public_identifier"]
    end

    test "casts the string booleans this format returns" do
      assert_equal false, @data["student"]
      assert_equal true, @data["verified"]
    end

    test "exposes the geo URN when LinkedIn withholds the location name" do
      location = @data["location"]

      assert_nil location["name"]
      assert_equal "gb", location["country_code"]
      assert_equal "urn:li:fsd_geo:115918471", location["geo_urn"]
    end

    test "builds image URLs by joining the root to each artifact segment" do
      picture = @data["profile_picture"]

      assert_equal "https://media.licdn.com/dms/image/root/400_400/pic.jpg", picture["url"]
      assert_equal [ 100, 400 ], picture["artifacts"].map { |a| a["width"] }
      assert_equal "https://media.licdn.com/dms/image/bg/1400_350/bg.jpg",
                   @data.dig("background_image", "url")
    end

    test "treats a missing end date as an ongoing role" do
      current, past = @data["experience"]

      assert current.dig("date_range", "current")
      assert_equal "June 1842", current.dig("date_range", "start", "text")
      assert_equal "London", current["location"]
      assert_not past.dig("date_range", "current")
      assert_equal "December 1841", past.dig("date_range", "end", "text")
    end

    test "maps education including a year-only date range" do
      school = @data["education"].sole

      assert_equal "Private Tutoring", school["school_name"]
      assert_equal "Mathematics", school["field_of_study"]
      assert_equal "1832", school.dig("date_range", "start", "text")
      assert_nil school["description"]
    end

    test "drops blank skills" do
      assert_equal [ "Mathematics", "Algorithms" ], @data["skills"]
    end

    test "selects entities by type suffix rather than full class path" do
      assert_equal "Certificate of Merit", @data.dig("certifications", 0, "name")
      assert_equal "NATIVE_OR_BILINGUAL", @data.dig("languages", 0, "proficiency")
    end

    test "emits every key even for an empty payload" do
      sparse = ProfileNormalizer.new(
        {}, public_identifier: "nobody", profile_url: "https://www.linkedin.com/in/nobody"
      ).call

      assert_equal @data.keys.sort, sparse.keys.sort
      assert_nil sparse["full_name"]
      assert_equal [], sparse["skills"]
      assert_equal [], sparse["experience"]
      assert_equal "nobody", sparse["public_identifier"]
    end

    test "tolerates a section that came back empty because it was unavailable" do
      payload = JSON.parse(file_fixture("dash_profile.json").read)
      payload["skills"] = { "included" => [] }

      data = ProfileNormalizer.new(
        payload, public_identifier: "ada-lovelace", profile_url: "https://x"
      ).call

      assert_equal [], data["skills"]
      assert_equal "Ada Lovelace", data["full_name"]
    end
  end
end
