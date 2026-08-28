module LinkedIn
  # Pulls a complete profile out of Voyager's `identity/dash/*` endpoints.
  #
  # LinkedIn retired the single aggregate endpoint (`profileView`, now HTTP
  # 410) along with several of its sub-resources. What replaced it is a set of
  # per-section finders, each keyed by the profile's URN rather than its public
  # slug. So a fetch is two stages:
  #
  #   1. resolve the slug to a profile entity, which carries both the identity
  #      fields and the `urn:li:fsd_profile:...` URN;
  #   2. fan out across the section finders using that URN.
  #
  # That costs one request per section instead of one per profile, which is why
  # caching and the outbound request budget matter as much as they do.
  class ProfileFetcher
    # This accept header selects Rest.li's normalized form: a flat `included`
    # array of typed entities rather than a deeply nested document.
    DASH_ACCEPT = "application/vnd.linkedin.normalized+json+2.1".freeze

    PROFILES_PATH = "identity/dash/profiles".freeze

    # Response key => the dash finder that populates it. Confirmed live;
    # the older identity/profiles/<slug>/{educations,skills} are both 410.
    SECTIONS = {
      "positions" => "profilePositions",
      "educations" => "profileEducations",
      "skills" => "profileSkills",
      "certifications" => "profileCertifications",
      "languages" => "profileLanguages"
    }.freeze

    EMPTY_SECTION = { "included" => [] }.freeze

    def initialize(public_identifier, client: Client.new)
      @public_identifier = public_identifier
      @client = client
    end

    def call
      profile_body = fetch_profile
      urn = profile_urn(profile_body)

      SECTIONS.each_with_object({ "profile" => profile_body }) do |(key, resource), payload|
        payload[key] = fetch_section(resource, urn)
      end
    end

    private

    attr_reader :public_identifier, :client

    def fetch_profile
      client.get(
        PROFILES_PATH,
        { q: "memberIdentity", memberIdentity: public_identifier },
        accept: DASH_ACCEPT
      )
    end

    # The profile entity is the one element in `included` carrying the slug.
    def profile_urn(body)
      entity = Array(body["included"]).find do |element|
        element.is_a?(Hash) && element["publicIdentifier"].present?
      end

      urn = entity&.dig("entityUrn")
      if urn.blank?
        raise ProfileNotFound,
              "LinkedIn returned no profile entity for #{public_identifier}"
      end

      urn
    end

    # A section that 404s or has been retired should cost us that section, not
    # the whole profile. Session and rate-limit failures are fatal and are
    # deliberately allowed to propagate.
    def fetch_section(resource, urn)
      client.get(
        "identity/dash/#{resource}",
        { q: "viewee", profileUrn: urn },
        accept: DASH_ACCEPT
      )
    rescue ProfileNotFound, UpstreamError => e
      Rails.logger.warn("[LinkedIn] section #{resource} unavailable: #{e.message}")
      EMPTY_SECTION
    end
  end
end
