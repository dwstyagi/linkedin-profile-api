# Inbound throttling.
#
# This protects the LinkedIn session rather than the server: every uncached
# request to this API becomes a request to LinkedIn, and a public endpoint
# that anyone can loop over is the fastest way to get the session banned.
class Rack::Attack
  THROTTLE_LIMIT = Integer(ENV.fetch("THROTTLE_REQUESTS_PER_MINUTE", 30))

  # Counters live in process memory rather than Rails.cache, which is a null
  # store in some environments and would silently disable throttling. This
  # service runs as a single instance, so per-process counters are accurate.
  self.cache.store = ActiveSupport::Cache::MemoryStore.new

  # Keyed by API key where one is presented, falling back to IP so that
  # unauthenticated floods are also capped.
  throttle("profile requests", limit: THROTTLE_LIMIT, period: 1.minute) do |request|
    next unless request.path.start_with?("/api/")

    request.get_header("HTTP_X_API_KEY").presence || request.ip
  end

  self.throttled_responder = lambda do |request|
    retry_after = (request.env["rack.attack.match_data"] || {})[:period].to_i

    [
      429,
      { "Content-Type" => "application/json", "Retry-After" => retry_after.to_s },
      [ { error: { code: "rate_limited",
                   message: "too many requests, retry in #{retry_after}s" } }.to_json ]
    ]
  end
end

Rails.application.config.middleware.use Rack::Attack
