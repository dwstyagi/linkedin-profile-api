require "test_helper"

module LinkedIn
  class ClientTest < ActiveSupport::TestCase
    setup { LinkedInRequest.delete_all }

    def config
      ActiveSupport::OrderedOptions.new.tap do |c|
        c.cookie = 'li_at=test; JSESSIONID="ajax:123"'
        c.user_agent = "test-agent"
        c.track = "{}"
        c.open_timeout = 1
        c.read_timeout = 1
        c.min_request_interval = 0.0
        c.daily_request_limit = 50
      end
    end

    # Replaces the transport so nothing leaves the machine.
    def client_raising(error)
      Client.new(config: config, budget: RequestBudget.new(config: config)).tap do |client|
        client.define_singleton_method(:connection) { raise error }
      end
    end

    test "a TLS failure surfaces as an upstream error rather than escaping" do
      # Faraday::SSLError descends from Faraday::Error, not ConnectionFailed.
      # Unhandled it would escape as a 500 and strand its reservation.
      error = assert_raises(UpstreamError) do
        client_raising(Faraday::SSLError.new("certificate verify failed")).get("me")
      end

      assert_match(/could not reach LinkedIn/, error.message)
    end

    test "a TLS failure leaves no reservation pending" do
      assert_raises(UpstreamError) do
        client_raising(Faraday::SSLError.new("certificate verify failed")).get("me")
      end

      assert_empty LinkedInRequest.where(outcome: "pending"),
                   "every reservation must be settled, or it silently consumes the budget"
      assert_equal [ "transport_error" ], LinkedInRequest.distinct.pluck(:outcome)
    end

    test "a TLS failure is retried, and every attempt is counted" do
      assert_raises(UpstreamError) do
        client_raising(Faraday::SSLError.new("boom")).get("me")
      end

      # One initial attempt plus MAX_RETRIES, each reserving its own slot.
      assert_equal Client::MAX_RETRIES + 1, LinkedInRequest.count
    end

    test "a non-retriable transport failure settles and gives up immediately" do
      assert_raises(UpstreamError) do
        client_raising(Faraday::Error.new("malformed")).get("me")
      end

      assert_equal 1, LinkedInRequest.count, "this class of failure is not worth retrying"
      assert_empty LinkedInRequest.where(outcome: "pending")
    end

    test "refuses to build without a configured session" do
      bare = ActiveSupport::OrderedOptions.new

      assert_raises(SessionExpired) { Client.new(config: bare) }
    end
  end
end
