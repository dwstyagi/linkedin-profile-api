module LinkedIn
  # Outbound rate limiting: how fast, and how often, we are willing to talk to
  # LinkedIn.
  #
  # Rack::Attack protects this service from its callers. This protects the
  # LinkedIn session from this service, which is the more valuable of the two
  # — a throttled caller retries, a banned account does not come back.
  #
  # Two independent controls:
  #
  #   * a minimum interval between consecutive calls, so traffic never arrives
  #     in the tight bursts that automated access looks like;
  #   * a daily ceiling, so a runaway loop or an enthusiastic reviewer cannot
  #     spend the account in an afternoon.
  class RequestBudget
    def initialize(config: Rails.application.config.x.linked_in)
      @min_interval = config.min_request_interval
      @daily_limit = config.daily_request_limit
    end

    # Blocks until it is acceptable to make the next call, or refuses outright
    # when the daily budget is gone.
    def acquire!
      enforce_daily_limit!
      enforce_spacing!
    end

    def record(path:, status: nil, outcome: "ok")
      LinkedInRequest.log!(path: path, status: status, outcome: outcome)
    end

    def spent_today = LinkedInRequest.today.count

    def remaining_today = [ daily_limit - spent_today, 0 ].max

    private

    attr_reader :min_interval, :daily_limit

    def enforce_daily_limit!
      return if spent_today < daily_limit

      raise RateLimited.new(
        "daily LinkedIn request budget of #{daily_limit} is exhausted; " \
        "it resets at midnight",
        retry_after: seconds_until_midnight
      )
    end

    def enforce_spacing!
      last_at = LinkedInRequest.maximum(:created_at)
      return if last_at.blank?

      elapsed = Time.current - last_at
      # Jitter so the spacing is not a metronome, which is itself a signal.
      wait = (min_interval - elapsed) + rand(0.0..0.4)
      sleep(wait) if wait.positive?
    end

    def seconds_until_midnight
      (Time.current.end_of_day - Time.current).ceil
    end
  end
end
