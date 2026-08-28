# Runtime configuration for the LinkedIn integration.
#
# Every value here comes from the environment. Nothing about the upstream
# session is ever committed to the repository. See .env.example.
Rails.application.config.x.linked_in = ActiveSupport::OrderedOptions.new.tap do |config|
  # Session cookies harvested manually from a logged-in browser during setup.
  # The running service never launches a browser; it only replays these values.
  config.li_at      = ENV["LINKEDIN_LI_AT"].presence
  config.jsessionid = ENV["LINKEDIN_JSESSIONID"].presence

  # Optional: an entire Cookie header copied from the browser. LinkedIn
  # sometimes answers with a redirect back to the same URL when supporting
  # cookies (bcookie, bscookie, lidc) are absent, so being able to replay the
  # whole jar is more reliable than sending li_at and JSESSIONID alone.
  # Takes precedence over the two values above when set.
  config.cookie = ENV["LINKEDIN_COOKIE"].presence

  # LinkedIn fingerprints unrecognised clients, so we present the same
  # user agent as the browser the session cookie was taken from.
  config.user_agent = ENV.fetch("LINKEDIN_USER_AGENT") {
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " \
    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
  }

  # Client fingerprint the LinkedIn web app sends on every request. Copy the
  # x-li-track header from a real browser request to keep this current.
  config.track = ENV.fetch("LINKEDIN_TRACK") {
    {
      clientVersion: "0.2.6975", mpVersion: "0.2.6975",
      osName: "web", mpName: "web",
      timezoneOffset: 5.5, timezone: "Asia/Calcutta",
      deviceFormFactor: "DESKTOP",
      displayDensity: 2, displayWidth: 3420, displayHeight: 2214
    }.to_json
  }

  # Outbound protection for the session: minimum seconds between calls to
  # LinkedIn, and the most calls we will make in a day.
  config.min_request_interval = Float(ENV.fetch("LINKEDIN_MIN_REQUEST_INTERVAL", 2.0))
  config.daily_request_limit  = Integer(ENV.fetch("LINKEDIN_DAILY_REQUEST_LIMIT", 100))

  config.open_timeout = Integer(ENV.fetch("LINKEDIN_OPEN_TIMEOUT", 5))
  config.read_timeout = Integer(ENV.fetch("LINKEDIN_READ_TIMEOUT", 15))
end

# How long a cached profile is served before we spend another upstream request.
Rails.application.config.x.profile_cache_ttl =
  Integer(ENV.fetch("PROFILE_CACHE_TTL_SECONDS", 86_400)).seconds

# Shared secret clients must present as X-API-Key.
Rails.application.config.x.api_key = ENV["API_KEY"].presence
