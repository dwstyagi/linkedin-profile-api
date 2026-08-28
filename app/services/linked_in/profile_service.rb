module LinkedIn
  # Entry point for the whole flow: URL in, normalized profile out.
  #
  #   LinkedIn::ProfileService.call(url: params[:url], refresh: false)
  #
  # Order matters here. Validation and the cache lookup both happen before any
  # network call, so malformed input and repeat requests never cost us an
  # upstream request against LinkedIn.
  class ProfileService
    Result = Struct.new(:data, :cached, :fetched_at, keyword_init: true)

    def self.call(...) = new(...).call

    def initialize(url:, refresh: false)
      @url = url
      @refresh = refresh
    end

    def call
      parsed = ProfileUrl.parse(url)

      cached = cached_profile_for(parsed)
      return result_for(cached, cached: true) if cached

      fetch_and_store(parsed)
    end

    private

    attr_reader :url, :refresh

    def cached_profile_for(parsed)
      return nil if refresh

      CachedProfile.fresh.find_by(public_identifier: parsed.public_identifier)
    end

    # Serialized per profile, so two simultaneous misses for the same person
    # do not both spend six upstream requests. The loser of the race waits,
    # then finds the winner's freshly written cache entry on the re-check.
    def fetch_and_store(parsed)
      CachedProfile.with_slug_lock(parsed.public_identifier) do
        cached = cached_profile_for(parsed)
        next result_for(cached, cached: true) if cached

        fetch_and_store!(parsed)
      end
    end

    def fetch_and_store!(parsed)
      raw_payload = ProfileFetcher.new(parsed.public_identifier).call

      data = ProfileNormalizer.new(
        raw_payload,
        public_identifier: parsed.public_identifier,
        profile_url: parsed.canonical_url
      ).call

      record = CachedProfile.store!(
        public_identifier: parsed.public_identifier,
        profile_url: parsed.canonical_url,
        data: data,
        raw_payload: raw_payload
      )

      result_for(record, cached: false)
    end

    def result_for(record, cached:)
      Result.new(data: record.data, cached: cached, fetched_at: record.fetched_at)
    end
  end
end
