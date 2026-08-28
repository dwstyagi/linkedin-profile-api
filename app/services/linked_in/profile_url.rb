module LinkedIn
  # Turns whatever URL a caller sends us into the profile slug LinkedIn's own
  # API is keyed by, rejecting anything that is not a member profile.
  #
  #   ProfileUrl.parse("https://www.linkedin.com/in/satyanadella/?trk=nav")
  #     #=> #<ProfileUrl public_identifier="satyanadella">
  class ProfileUrl
    # Matches www., in., uk. and friends, but nothing that merely ends in
    # "linkedin.com" such as "notlinkedin.com".
    HOST = /\A([a-z0-9-]+\.)*linkedin\.com\z/i

    # Member profiles live under /in/<slug>. Companies (/company/), schools
    # (/school/) and posts (/posts/) are deliberately not supported.
    PATH = %r{\A/in/(?<slug>[^/]+)/?}

    attr_reader :public_identifier

    def self.parse(input) = new(input).tap(&:parse!)

    def initialize(input)
      @input = input.to_s.strip
    end

    def parse!
      raise InvalidProfileUrl, "url is required" if @input.blank?

      uri = parse_uri
      validate_host!(uri)
      @public_identifier = extract_slug(uri)
      self
    end

    # A stable, canonical form we echo back and store, so the same profile
    # reached through different tracking URLs is cached once.
    def canonical_url = "https://www.linkedin.com/in/#{public_identifier}"

    private

    def parse_uri
      # Accept "linkedin.com/in/foo" as well as a fully qualified URL.
      candidate = @input.match?(%r{\Ahttps?://}i) ? @input : "https://#{@input}"
      URI.parse(candidate)
    rescue URI::InvalidURIError
      raise InvalidProfileUrl, "#{@input.inspect} is not a valid URL"
    end

    def validate_host!(uri)
      return if uri.host&.match?(HOST)

      raise InvalidProfileUrl, "#{@input.inspect} is not a linkedin.com URL"
    end

    def extract_slug(uri)
      match = PATH.match(uri.path.to_s)
      unless match
        raise InvalidProfileUrl,
              "only member profile URLs (linkedin.com/in/...) are supported"
      end

      # Slugs may be percent-encoded when they contain non-ASCII characters.
      slug = CGI.unescape(match[:slug])
      raise InvalidProfileUrl, "profile identifier is missing" if slug.blank?

      slug
    end
  end
end
