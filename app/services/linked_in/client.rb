require "faraday"
require "faraday/retry"

module LinkedIn
  # Thin HTTP client for LinkedIn's internal Voyager API.
  #
  # This is a plain HTTP client and nothing more: no browser, no automation
  # driver, no headless Chrome. It replays the same request a logged-in
  # browser tab would make, using a session cookie supplied via the
  # environment, and maps upstream status codes onto our own error classes.
  #
  # It does keep a cookie jar, because LinkedIn requires it. `lidc` is a
  # routing cookie carrying an expiry timestamp; once it goes stale LinkedIn
  # answers with a redirect back to the same URL and a Set-Cookie header
  # carrying a fresh one. Replaying a fixed cookie string therefore works
  # until it abruptly doesn't. Absorbing Set-Cookie and retrying is what a
  # browser does, and is the difference between a client that works for one
  # request and one that keeps working.
  class Client
    BASE_URL = "https://www.linkedin.com".freeze
    API_PREFIX = "/voyager/api".freeze

    # Redirects are cookie refreshes, not navigation, so one hop is plenty.
    # More than that means something else is wrong and we should stop rather
    # than hammer the endpoint.
    MAX_REDIRECTS = 2

    # Retrying an auth failure or a throttle just burns the session faster,
    # so only transient transport-level problems are retried.
    RETRIABLE_STATUSES = [ 500, 502, 503, 504 ].freeze
    # Faraday::SSLError descends from Faraday::Error rather than
    # ConnectionFailed, so it has to be named explicitly. A TLS handshake can
    # fail transiently, so it is worth one retry.
    RETRIABLE_EXCEPTIONS = [
      Faraday::TimeoutError,
      Faraday::ConnectionFailed,
      Faraday::SSLError
    ].freeze

    # Retries are performed here rather than by Faraday middleware. Middleware
    # retries are invisible to the request budget: one reservation would cover
    # up to three requests LinkedIn actually receives, so the daily count and
    # the spacing between calls would both understate reality precisely when
    # things are going wrong. Retrying at this level means every attempt
    # reserves its own slot and is recorded.
    MAX_RETRIES = 2
    RETRY_BACKOFF = 0.5

    # LinkedIn expires a cookie by setting this literal value with Max-Age=0.
    DELETION_MARKER = "delete me".freeze

    # Cookies we refuse to send back. `li_g_recent_logout` is a flag LinkedIn
    # sets when a browser signs out; replaying it alongside a live session
    # tells LinkedIn the session should not exist. It is routinely present in
    # a cookie header copied from a browser that has ever logged out.
    IGNORED_COOKIES = %w[li_g_recent_logout].freeze

    def initialize(config: Rails.application.config.x.linked_in, budget: RequestBudget.new)
      @config = config
      @budget = budget
      validate_session!
      @jar = initial_jar
    end

    # GET a Voyager path relative to /voyager/api and return the parsed body.
    #
    #   client.get("identity/dash/profiles", q: "memberIdentity", ...)
    def get(path, params = {}, accept: "application/json")
      perform(path, params, accept, MAX_REDIRECTS)
    end

    # Cheap authenticated call used by the health endpoint to report whether
    # the configured session is still alive, without fetching a profile.
    def session_alive?
      get("me")
      true
    rescue SessionExpired
      false
    end

    private

    attr_reader :config, :jar, :budget

    def perform(path, params, accept, redirects_left)
      response = request_with_retries(path, params, accept)
      absorb_cookies(response)

      return handle(response) unless response.status.between?(300, 399)

      # A redirect that also expires li_at is a rejection, not a refresh.
      raise SessionExpired,
            "LinkedIn cleared the session cookie; the credentials were rejected" if session_cleared?

      raise SessionExpired,
            "LinkedIn kept redirecting #{path} after refreshing cookies" if redirects_left.zero?

      # The Location is the same URL; the point of the round trip was the new
      # cookie, which we now hold, so replay the original request.
      perform(path, params, accept, redirects_left - 1)
    end

    # Every attempt — first try and each retry alike — reserves its own slot
    # in the budget before leaving and is settled with its outcome after, so
    # the daily count and the spacing reflect what LinkedIn actually received.
    def request_with_retries(path, params, accept)
      attempt = 0

      loop do
        attempt += 1
        reservation = budget.reserve!(path)

        begin
          response = connection.get(File.join(API_PREFIX, path), params) do |request|
            request.headers["cookie"] = cookie_header
            request.headers["csrf-token"] = csrf_token
            request.headers["accept"] = accept
          end

          budget.settle(reservation, status: response.status, outcome: outcome_for(response))
          return response unless RETRIABLE_STATUSES.include?(response.status)
          raise UpstreamError, "LinkedIn returned HTTP #{response.status}" if attempt > MAX_RETRIES
        rescue *RETRIABLE_EXCEPTIONS => e
          budget.settle(reservation, outcome: "transport_error")
          raise UpstreamError, "could not reach LinkedIn: #{e.class}" if attempt > MAX_RETRIES
        rescue Faraday::Error => e
          # Any other transport failure is not worth retrying, but it still
          # has to settle its reservation and surface as an upstream error.
          # Left unhandled it would escape as a 500 and strand the
          # reservation as pending, quietly consuming the day's budget.
          budget.settle(reservation, outcome: "transport_error")
          raise UpstreamError, "could not reach LinkedIn: #{e.class}"
        end

        sleep(RETRY_BACKOFF * (2**(attempt - 1)))
      end
    end

    def outcome_for(response)
      case response.status
      when 200..299 then "ok"
      when 300..399 then "redirect"
      when 410 then "gone"
      else "error"
      end
    end

    def validate_session!
      return if config.cookie.present? || (config.li_at.present? && config.jsessionid.present?)

      raise SessionExpired,
            "configure either LINKEDIN_COOKIE, or both LINKEDIN_LI_AT and " \
            "LINKEDIN_JSESSIONID"
    end

    # --- cookies --------------------------------------------------------

    def initial_jar
      return parse_cookie_header(config.cookie) if config.cookie.present?

      # LinkedIn sets JSESSIONID with literal quotes and expects them back.
      { "li_at" => config.li_at, "JSESSIONID" => %("#{unquote(config.jsessionid)}") }
    end

    def parse_cookie_header(header)
      header.to_s.split(";").each_with_object({}) do |pair, jar|
        name, value = pair.strip.split("=", 2)
        next if name.blank? || value.nil? || IGNORED_COOKIES.include?(name)

        jar[name] = value
      end
    end

    # Set-Cookie headers arrive joined by commas, and Expires values contain
    # commas of their own ("Expires=Thu, 01-Jan-1970"). Split only where a
    # comma is followed by something that looks like a new cookie name.
    def absorb_cookies(response)
      raw = response.headers["set-cookie"].to_s
      return if raw.blank?

      raw.split(/,\s*(?=[A-Za-z0-9_\-]+=)/).each do |directive|
        name, value = directive.split(";").first.to_s.strip.split("=", 2)
        next if name.blank? || value.nil? || IGNORED_COOKIES.include?(name)

        # Never write an expiry back into the jar; that would make every
        # subsequent request present a cookie LinkedIn has just revoked.
        if name == "li_at" && unquote(value) == DELETION_MARKER
          @session_cleared = true
          next
        end

        jar[name] = value
      end
    end

    def session_cleared? = @session_cleared.present?

    def cookie_header = jar.map { |name, value| "#{name}=#{value}" }.join("; ")

    # The CSRF token is always the current JSESSIONID value, which can be
    # rotated by a Set-Cookie mid-session.
    def csrf_token = unquote(jar["JSESSIONID"].to_s)

    def unquote(value) = value.to_s.delete('"')

    # --- transport ------------------------------------------------------

    def connection
      # Deliberately no retry middleware: retries happen in
      # #request_with_retries so the budget sees every attempt.
      @connection ||= Faraday.new(url: BASE_URL, headers: static_headers) do |f|
        f.options.open_timeout = config.open_timeout
        f.options.timeout = config.read_timeout
        f.adapter Faraday.default_adapter
      end
    end

    def static_headers
      {
        "x-restli-protocol-version" => "2.0.0",
        "x-li-lang" => "en_US",
        # The web client sends this on every call. Omitting it is one of the
        # clearer signals that a request did not come from the LinkedIn app.
        "x-li-track" => config.track,
        "user-agent" => config.user_agent,
        "accept-language" => "en-US,en;q=0.9",
        "origin" => BASE_URL,
        "referer" => "#{BASE_URL}/feed/",
        "sec-fetch-dest" => "empty",
        "sec-fetch-mode" => "cors",
        "sec-fetch-site" => "same-origin"
      }
    end

    def handle(response)
      case response.status
      when 200..299 then parse_body(response)
      when 401, 403
        raise SessionExpired,
              "LinkedIn rejected the session cookie (HTTP #{response.status})"
      when 404
        raise ProfileNotFound, "LinkedIn returned 404 for this resource"
      when 410
        raise UpstreamError,
              "LinkedIn has retired this endpoint (HTTP 410)"
      when 429
        raise RateLimited.new(retry_after: response.headers["retry-after"])
      else
        Rails.logger.error(
          "[LinkedIn] unexpected #{response.status}: #{response.body.to_s.truncate(500)}"
        )
        raise UpstreamError, "LinkedIn returned HTTP #{response.status}"
      end
    end

    def parse_body(response)
      JSON.parse(response.body.to_s)
    rescue JSON::ParserError
      # A 200 carrying HTML rather than JSON is how LinkedIn serves its
      # login wall and security checkpoints, so treat it as a dead session.
      raise SessionExpired,
            "LinkedIn returned a non-JSON body, the session is likely blocked " \
            "or challenged"
    end
  end
end
