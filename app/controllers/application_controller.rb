class ApplicationController < ActionController::API
  before_action :authenticate!

  # Upstream failures are translated into honest status codes. The important
  # distinction is between a caller problem (4xx) and our session having died
  # (503) — the latter is an operator problem and should never look like a bug
  # in the caller's request.
  rescue_from LinkedIn::InvalidProfileUrl do |e|
    render_error(:unprocessable_content, "invalid_url", e.message)
  end

  rescue_from LinkedIn::ProfileNotFound do |e|
    render_error(:not_found, "profile_not_found", e.message)
  end

  rescue_from LinkedIn::RateLimited do |e|
    response.headers["Retry-After"] = e.retry_after if e.retry_after.present?
    render_error(:too_many_requests, "rate_limited", e.message)
  end

  rescue_from LinkedIn::SessionExpired do |e|
    render_error(:service_unavailable, "linkedin_session_expired", e.message)
  end

  rescue_from LinkedIn::UpstreamError do |e|
    render_error(:bad_gateway, "upstream_error", e.message)
  end

  private

  def authenticate!
    return if api_key_configured? && secure_match?(request.headers["X-API-Key"])

    render_error(:unauthorized, "unauthorized", "a valid X-API-Key header is required")
  end

  def api_key_configured?
    Rails.application.config.x.api_key.present?
  end

  def secure_match?(presented)
    return false if presented.blank?

    ActiveSupport::SecurityUtils.secure_compare(
      presented, Rails.application.config.x.api_key
    )
  end

  def render_error(status, code, message)
    render json: { error: { code: code, message: message } }, status: status
  end
end
