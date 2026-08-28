# The one unauthenticated endpoint: a signpost for anyone who opens the
# deployed base URL in a browser and wonders what this is.
class RootController < ApplicationController
  skip_before_action :authenticate!

  def show
    render json: {
      service: "LinkedIn Profile API",
      description: "Returns a LinkedIn member profile as structured JSON.",
      endpoints: {
        profile: "GET /api/v1/profile?url=<linkedin profile url>",
        health: "GET /api/v1/health"
      },
      authentication: "send your key in the X-API-Key header"
    }
  end
end
