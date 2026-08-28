module Api
  module V1
    class ProfilesController < ApplicationController
      # GET /api/v1/profile?url=https://www.linkedin.com/in/<slug>
      #
      # Pass refresh=true to bypass the cache and force a fresh upstream fetch.
      def show
        result = LinkedIn::ProfileService.call(
          url: params[:url],
          refresh: ActiveModel::Type::Boolean.new.cast(params[:refresh]).present?
        )

        render json: {
          data: result.data,
          meta: {
            cached: result.cached,
            fetched_at: result.fetched_at.utc.iso8601,
            source: "linkedin_voyager"
          }
        }
      end
    end
  end
end
