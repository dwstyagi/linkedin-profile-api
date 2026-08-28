# A profile we have already fetched from LinkedIn.
#
# The cache exists to protect the upstream session, not to save milliseconds:
# every cache hit is one fewer request against LinkedIn, and request volume is
# what gets a session challenged or banned.
class CachedProfile < ApplicationRecord
  validates :public_identifier, presence: true, uniqueness: true
  validates :profile_url, :fetched_at, presence: true

  scope :fresh, -> { where(fetched_at: ttl.ago..) }

  def self.ttl = Rails.application.config.x.profile_cache_ttl

  def self.store!(public_identifier:, profile_url:, data:, raw_payload:)
    record = find_or_initialize_by(public_identifier: public_identifier)
    record.update!(
      profile_url: profile_url,
      data: data,
      raw_payload: raw_payload,
      fetched_at: Time.current
    )
    record
  end

  def stale? = fetched_at < self.class.ttl.ago
end
