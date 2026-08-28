# Namespace for everything that talks to LinkedIn.
#
# The error classes live here, in the namespace file itself, so that a
# reference to any one of them (LinkedIn::SessionExpired and friends) loads
# them all. Zeitwerk maps files to constants by name, so a separate errors.rb
# defining several differently-named classes would never be autoloaded.
module LinkedIn
  # Base class for every upstream failure. The controller maps each subclass
  # onto an HTTP status so callers can tell "our session died" apart from
  # "this profile does not exist" apart from "we have a bug".
  class Error < StandardError; end

  # The supplied URL was not a LinkedIn member profile URL. -> 422
  class InvalidProfileUrl < Error; end

  # The configured cookies are missing, malformed or no longer valid. -> 503
  # This is an operator problem, not a caller problem, hence not a 401.
  class SessionExpired < Error; end

  # LinkedIn has no such member, or the session cannot see them at all. -> 404
  class ProfileNotFound < Error; end

  # LinkedIn is throttling us. -> 429
  class RateLimited < Error
    attr_reader :retry_after

    def initialize(message = "LinkedIn rate limited this session", retry_after: nil)
      @retry_after = retry_after
      super(message)
    end
  end

  # Anything else upstream: 5xx, unparseable bodies, connection failures. -> 502
  class UpstreamError < Error; end
end
