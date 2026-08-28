require "test_helper"

module LinkedIn
  class RequestBudgetTest < ActiveSupport::TestCase
    setup do
      LinkedInRequest.delete_all
    end

    # Zero spacing keeps the suite fast; the spacing behaviour itself is
    # asserted separately with an explicit interval.
    def budget(min_interval: 0.0, daily_limit: 5)
      config = ActiveSupport::OrderedOptions.new
      config.min_request_interval = min_interval
      config.daily_request_limit = daily_limit
      RequestBudget.new(config: config)
    end

    test "a reservation is committed before the request is made" do
      reservation = budget.reserve!("identity/dash/profiles")

      assert_predicate reservation, :persisted?
      assert_equal "pending", reservation.outcome
      assert_equal "identity/dash/profiles", reservation.path
      assert_equal 1, LinkedInRequest.count
    end

    test "settling records the outcome without creating a second row" do
      b = budget
      reservation = b.reserve!("identity/dash/profileSkills")

      b.settle(reservation, status: 200, outcome: "ok")

      assert_equal 1, LinkedInRequest.count
      assert_equal [ 200, "ok" ], reservation.reload.then { |r| [ r.status, r.outcome ] }
    end

    test "a pending reservation still counts against the day" do
      b = budget(daily_limit: 5)
      b.reserve!("identity/dash/profiles")

      # Never settled — the request was made regardless, and LinkedIn saw it.
      assert_equal 1, b.spent_today
      assert_equal 4, b.remaining_today
    end

    test "slots are spaced by at least the configured interval" do
      b = budget(min_interval: 0.5)

      first = b.reserve!("a")
      second = b.reserve!("b")

      assert_operator second.created_at - first.created_at, :>=, 0.5
    end

    test "refuses once the daily budget is spent" do
      b = budget(daily_limit: 2)
      b.reserve!("a")
      b.reserve!("b")

      error = assert_raises(RateLimited) { b.reserve!("c") }

      assert_match(/budget of 2 is exhausted/, error.message)
      assert_operator error.retry_after, :>, 0
      assert_equal 2, LinkedInRequest.count, "a refused reservation must not be recorded"
    end

    test "failed requests count too" do
      b = budget
      reservation = b.reserve!("identity/dash/profiles")
      b.settle(reservation, status: 410, outcome: "gone")

      assert_equal 1, b.spent_today
      assert_equal 1, LinkedInRequest.today.failed.count
    end
  end
end
