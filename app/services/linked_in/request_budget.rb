module LinkedIn
  # Outbound rate limiting: how fast, and how often, we are willing to talk to
  # LinkedIn.
  #
  # Rack::Attack protects this service from its callers. This protects the
  # LinkedIn session from this service, which is the more valuable of the two
  # — a throttled caller retries, a banned account does not come back.
  #
  # Two controls:
  #
  #   * a minimum interval between consecutive calls, so traffic never arrives
  #     in the tight bursts that automated access looks like;
  #   * a daily ceiling, so a runaway loop or an enthusiastic reviewer cannot
  #     spend the account in an afternoon.
  #
  # Both are enforced by *reserving a slot before the request is made* rather
  # than checking a counter and hoping. A reservation is a committed row
  # stamped with the time its request is allowed to leave. Concurrent threads
  # take an advisory lock to claim slots, so they queue up behind each other
  # instead of reading the same count and all passing at once; the waiting
  # itself happens outside the lock, so a thread sleeping until its slot does
  # not block others from claiming later ones.
  #
  # The reservation is settled with the outcome once the request completes,
  # which also means a request that fails still counts — it was made, and
  # LinkedIn saw it.
  class RequestBudget
    # Arbitrary constant identifying this application's throttle lock.
    ADVISORY_LOCK_KEY = 4_827_193_004

    def initialize(config: Rails.application.config.x.linked_in)
      @min_interval = config.min_request_interval
      @daily_limit = config.daily_request_limit
    end

    # Claims the next slot and blocks until it arrives. Returns the
    # reservation, which must be handed back to #settle.
    #
    # Raises RateLimited if the day's budget is already spent.
    def reserve!(path)
      reservation = with_advisory_lock do
        enforce_daily_limit!
        LinkedInRequest.create!(path: path, outcome: "pending", created_at: next_slot)
      end

      wait = reservation.created_at - Time.current
      sleep(wait) if wait.positive?

      reservation
    end

    def settle(reservation, status: nil, outcome: "ok")
      reservation.update!(status: status, outcome: outcome)
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

    # The next moment a request may leave: one interval after the most
    # recently claimed slot, or now if that is already in the past. Jitter
    # keeps the spacing from being a metronome, which is itself a signal.
    def next_slot
      last_claimed = LinkedInRequest.maximum(:created_at)
      now = Time.current
      return now if last_claimed.blank?

      [ last_claimed + min_interval + rand(0.0..0.4), now ].max
    end

    # Serializes slot claims across threads and processes. Held only for the
    # claim itself, never while waiting for a slot to arrive.
    def with_advisory_lock
      connection = LinkedInRequest.connection
      connection.execute("SELECT pg_advisory_lock(#{ADVISORY_LOCK_KEY})")
      yield
    ensure
      connection&.execute("SELECT pg_advisory_unlock(#{ADVISORY_LOCK_KEY})")
    end

    def seconds_until_midnight
      (Time.current.end_of_day - Time.current).ceil
    end
  end
end
