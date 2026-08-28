module LinkedIn
  # Translates the `identity/dash/*` payloads into the schema this API
  # publishes.
  #
  # The upstream format is Rest.li's normalized form: each response carries a
  # flat `included` array of typed entities, tagged with a `$type` such as
  # "com.linkedin.voyager.dash.identity.profile.Position". Entities are flat
  # and reference each other by URN, so normalizing is mostly selecting the
  # right `$type` out of the right section and renaming fields.
  #
  # Two rules govern everything here:
  #
  # 1. Never assume a field exists. Real profiles are missing an About
  #    section, an end date, an entire section. Every accessor digs and every
  #    list defaults to empty, so a sparse profile returns a sparse-but-valid
  #    document rather than raising.
  # 2. Always emit the same keys. Callers can rely on the shape; absent data
  #    is null, not a missing key.
  class ProfileNormalizer
    def initialize(payload, public_identifier:, profile_url:)
      @payload = payload.is_a?(Hash) ? payload : {}
      @public_identifier = public_identifier
      @profile_url = profile_url
    end

    def call
      {
        "public_identifier" => profile["publicIdentifier"].presence || public_identifier,
        "profile_url" => profile_url,
        "member_id" => member_id,
        "first_name" => profile["firstName"].presence,
        "last_name" => profile["lastName"].presence,
        "full_name" => full_name,
        "headline" => profile["headline"].presence,
        "about" => profile["summary"].presence,
        "industry_urn" => profile["industryUrn"].presence,
        "student" => boolean(profile["student"]),
        "verified" => boolean(profile["showVerificationBadge"]),
        "location" => location,
        "profile_picture" => image(profile["profilePicture"]),
        "background_image" => image(profile["backgroundPicture"]),
        "experience" => experience,
        "education" => education,
        "skills" => skills,
        "certifications" => certifications,
        "languages" => languages
      }
    end

    private

    attr_reader :payload, :public_identifier, :profile_url

    # The profile entity is the element in `included` carrying the slug.
    def profile
      @profile ||= entities("profile").find { |e| e["publicIdentifier"].present? } || {}
    end

    def full_name
      [ profile["firstName"], profile["lastName"] ].compact_blank.join(" ").presence
    end

    def member_id
      profile["objectUrn"].to_s[/urn:li:member:(\d+)/, 1]
    end

    def location
      {
        # Without a decoration LinkedIn returns the geo as a URN only, so the
        # human-readable name is frequently absent. The URN is exposed so a
        # caller can resolve it if they need to.
        "name" => profile["geoLocationName"].presence || profile["locationName"].presence,
        "country_code" => profile.dig("location", "countryCode").presence,
        "postal_code" => profile.dig("location", "postalCode").presence,
        "geo_urn" => profile.dig("geoLocation", "geoUrn").presence
      }
    end

    # --- sections -------------------------------------------------------

    def experience
      entities("positions", "Position").map do |position|
        {
          "title" => position["title"].presence,
          "company_name" => position["companyName"].presence,
          "company_urn" => position["companyUrn"].presence,
          "employment_type_urn" => position["employmentTypeUrn"].presence,
          "location" => position["geoLocationName"].presence || position["locationName"].presence,
          "description" => position["description"].presence,
          "date_range" => date_range(position["dateRange"])
        }
      end
    end

    def education
      entities("educations", "Education").map do |school|
        {
          "school_name" => school["schoolName"].presence,
          "school_urn" => school["schoolUrn"].presence,
          "degree_name" => school["degreeName"].presence,
          "field_of_study" => school["fieldOfStudy"].presence,
          "grade" => school["grade"].presence,
          "activities" => school["activities"].presence,
          "description" => school["description"].presence,
          "date_range" => date_range(school["dateRange"])
        }
      end
    end

    def skills
      entities("skills", "Skill").filter_map { |skill| skill["name"].presence }
    end

    def certifications
      entities("certifications", "Certification").map do |certification|
        {
          "name" => certification["name"].presence,
          "authority" => certification["authority"].presence,
          "license_number" => certification["licenseNumber"].presence,
          "url" => certification["url"].presence,
          "company_urn" => certification["companyUrn"].presence,
          "date_range" => date_range(certification["dateRange"])
        }
      end
    end

    def languages
      entities("languages", "Language").map do |language|
        { "name" => language["name"].presence, "proficiency" => language["proficiency"].presence }
      end
    end

    # --- helpers --------------------------------------------------------

    # Pulls the `included` entities out of one section's response, optionally
    # keeping only one $type. Matching on the trailing segment keeps this
    # working when LinkedIn moves a class between packages.
    def entities(section_key, type_suffix = nil)
      included = payload.dig(section_key, "included")
      return [] unless included.is_a?(Array)

      elements = included.select { |element| element.is_a?(Hash) }
      return elements if type_suffix.blank?

      elements.select { |element| element["$type"].to_s.split(".").last == type_suffix }
    end

    # This format returns booleans as the strings "true" and "false".
    def boolean(value)
      return value if value == true || value == false
      return nil if value.blank?

      ActiveModel::Type::Boolean.new.cast(value)
    end

    def date_range(range)
      range = {} unless range.is_a?(Hash)
      starts_at = date(range["start"])
      ends_at = date(range["end"])

      {
        "start" => starts_at,
        "end" => ends_at,
        # LinkedIn omits the end entirely for anything ongoing.
        "current" => starts_at.present? && ends_at.blank?
      }
    end

    def date(node)
      return nil unless node.is_a?(Hash)

      year = node["year"]
      month = node["month"]
      day = node["day"]
      return nil if year.blank? && month.blank?

      { "year" => year, "month" => month, "day" => day, "text" => date_text(year, month) }
    end

    def date_text(year, month)
      month_name = Date::MONTHNAMES[month] if month.is_a?(Integer) && month.between?(1, 12)
      [ month_name, year ].compact.join(" ").presence
    end

    # LinkedIn images arrive as a "vector image": a root URL plus a list of
    # size artifacts whose path segments are appended to it. The wrapper key
    # differs between endpoints, so we search for the shape rather than a
    # fixed key path.
    def image(node)
      vector = find_vector_image(node)
      return nil unless vector

      root = vector["rootUrl"].to_s
      artifacts = Array(vector["artifacts"]).filter_map do |artifact|
        next unless artifact.is_a?(Hash)
        segment = artifact["fileIdentifyingUrlPathSegment"]
        next if segment.blank?

        {
          "width" => artifact["width"],
          "height" => artifact["height"],
          "url" => "#{root}#{segment}"
        }
      end.sort_by { |artifact| artifact["width"].to_i }

      return nil if artifacts.empty?

      # Largest rendition as the headline value, every size alongside it so a
      # caller can pick a thumbnail without another round trip.
      { "url" => artifacts.last["url"], "artifacts" => artifacts }
    end

    def find_vector_image(node)
      return nil unless node.is_a?(Hash)
      return node if node.key?("rootUrl") && node.key?("artifacts")

      node.each_value do |value|
        found = find_vector_image(value)
        return found if found
      end

      nil
    end
  end
end
