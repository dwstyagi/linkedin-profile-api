# A profile we have already fetched from LinkedIn.
#
# The cache exists to protect the upstream session, not to save milliseconds:
# every cache hit is one fewer request against LinkedIn, and request volume is
# what gets a session challenged or banned.
require "zlib"

class CachedProfile < ApplicationRecord
  # Namespace for this model's per-profile advisory locks, keeping them from
  # colliding with the throttle lock in LinkedIn::RequestBudget.
  LOCK_NAMESPACE = 71_113

  validates :public_identifier, presence: true, uniqueness: true
  validates :profile_url, :fetched_at, presence: true

  scope :fresh, -> { where(fetched_at: ttl.ago..) }

  def self.ttl = Rails.application.config.x.profile_cache_ttl

  def self.store!(public_identifier:, profile_url:, data:, raw_payload:)
    attempts = 0

    begin
      attempts += 1
      record = find_or_initialize_by(public_identifier: public_identifier)
      record.update!(
        profile_url: profile_url,
        data: data,
        raw_payload: raw_payload,
        fetched_at: Time.current
      )
      record
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      # Another request inserted this profile between our lookup and our
      # write. Which error surfaces depends on the interleaving: the
      # uniqueness validation raises RecordInvalid if the row landed before
      # it ran, the unique index raises RecordNotUnique if it landed after.
      # Either way the retry finds the existing row and updates it.
      raise if attempts > 1 || !duplicate_profile?(e)

      retry
    end
  end

  # A genuine duplicate, as opposed to some other validation failure that
  # retrying would only repeat.
  def self.duplicate_profile?(error)
    return true if error.is_a?(ActiveRecord::RecordNotUnique)

    error.record.errors.of_kind?(:public_identifier, :taken)
  end
  private_class_method :duplicate_profile?

  # Serializes work on one profile across threads and processes, so two
  # concurrent misses for the same person do not both spend six upstream
  # requests. The key is derived from the slug, so different profiles never
  # wait on each other.
  def self.with_slug_lock(public_identifier)
    key = Zlib.crc32(public_identifier) % 2_147_483_647
    advisory("pg_advisory_lock", key)
    yield
  ensure
    advisory("pg_advisory_unlock", key)
  end

  # Bound parameters rather than interpolation. The values are integers we
  # derive ourselves, but that is not provable from the call site, and a
  # string-built query here would be indistinguishable from one that is
  # genuinely unsafe.
  def self.advisory(function, key)
    sql = function == "pg_advisory_lock" ? "SELECT pg_advisory_lock($1, $2)" : "SELECT pg_advisory_unlock($1, $2)"

    connection.exec_query(sql, "advisory lock", [
      ActiveRecord::Relation::QueryAttribute.new("namespace", LOCK_NAMESPACE, ActiveRecord::Type::Integer.new),
      ActiveRecord::Relation::QueryAttribute.new("key", key, ActiveRecord::Type::Integer.new)
    ])
  end
  private_class_method :advisory

  def stale? = fetched_at < self.class.ttl.ago
end
