# One row per request made to LinkedIn.
#
# Deliberately append-only and cheap to write: it is both the counter behind
# the outbound rate limiter and the evidence trail for how the session is
# holding up.
class LinkedInRequest < ApplicationRecord
  # created_at is set explicitly; there is no updated_at on this table.
  self.record_timestamps = false

  scope :today, -> { where(created_at: Time.current.beginning_of_day..) }
  scope :failed, -> { where.not(outcome: "ok") }

  def self.log!(path:, status: nil, outcome: "ok")
    create!(path: path, status: status, outcome: outcome, created_at: Time.current)
  end
end
