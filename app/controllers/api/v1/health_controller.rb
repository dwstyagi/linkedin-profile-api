module Api
  module V1
    # Reports whether the configured LinkedIn session still authenticates.
    #
    # Worth its own endpoint because the failure mode of this service is not
    # "the app crashed", it is "the cookie quietly expired". This turns that
    # into something an operator can check directly.
    #
    # It costs one upstream request, so it sits behind the API key like
    # everything else. Platform health checks should use /up instead.
    class HealthController < ApplicationController
      def show
        budget = LinkedIn::RequestBudget.new
        alive = LinkedIn::Client.new(budget: budget).session_alive?

        render json: {
          data: {
            linkedin_session: alive ? "active" : "expired",
            cached_profiles: CachedProfile.count,
            requests_today: budget.spent_today,
            requests_remaining_today: budget.remaining_today,
            failures_today: LinkedInRequest.today.failed.count
          }
        }, status: alive ? :ok : :service_unavailable
      rescue LinkedIn::SessionExpired => e
        # A missing or malformed cookie raises during client construction.
        render json: {
          data: { linkedin_session: "unconfigured", detail: e.message }
        }, status: :service_unavailable
      end
    end
  end
end
