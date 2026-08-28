ENV["RAILS_ENV"] ||= "test"

# The suite never talks to LinkedIn, but the app still needs an API key to
# authenticate requests. Set before the environment loads so the initializer
# picks it up, and so the suite does not depend on a local .env file.
ENV["API_KEY"] ||= "test-api-key"

require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Swaps LinkedIn::ProfileFetcher for a double for the duration of a block,
    # so integration tests exercise the real controller and service without a
    # LinkedIn session. Minitest 6 no longer ships minitest/mock, and this is
    # the only seam the suite needs, so it does not warrant a mocking gem.
    def with_fetcher(double)
      original = LinkedIn::ProfileFetcher.method(:new)
      LinkedIn::ProfileFetcher.define_singleton_method(:new) { |*| double }
      yield
    ensure
      LinkedIn::ProfileFetcher.define_singleton_method(:new, original)
    end
  end
end
