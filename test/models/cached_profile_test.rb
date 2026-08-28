require "test_helper"

class CachedProfileTest < ActiveSupport::TestCase
  def store(name: "Ada Lovelace")
    CachedProfile.store!(
      public_identifier: "ada-lovelace",
      profile_url: "https://www.linkedin.com/in/ada-lovelace",
      data: { "full_name" => name },
      raw_payload: { "profile" => {} }
    )
  end

  test "storing the same profile twice updates rather than duplicates" do
    store
    store(name: "Ada King")

    assert_equal 1, CachedProfile.count
    assert_equal "Ada King", CachedProfile.sole.data["full_name"]
  end

  test "recovers when another writer inserts the row first" do
    # Simulates the race the unique index protects against: the lookup finds
    # nothing, but by the time we write, someone else has inserted.
    raised = false
    CachedProfile.singleton_class.prepend(Module.new do
      define_method(:find_or_initialize_by) do |args|
        unless raised
          raised = true
          CachedProfile.insert!({
            public_identifier: "ada-lovelace",
            profile_url: "https://www.linkedin.com/in/ada-lovelace",
            data: {}, raw_payload: {}, fetched_at: Time.current,
            created_at: Time.current, updated_at: Time.current
          })
          return CachedProfile.new(public_identifier: "ada-lovelace")
        end
        super(args)
      end
    end)

    assert_nothing_raised { store(name: "Ada Recovered") }
    assert_equal 1, CachedProfile.count
    assert_equal "Ada Recovered", CachedProfile.sole.data["full_name"]
  end

  test "fresh excludes entries older than the TTL" do
    record = store
    assert_equal [ record ], CachedProfile.fresh.to_a

    record.update!(fetched_at: (CachedProfile.ttl + 1.minute).ago)

    assert_empty CachedProfile.fresh
    assert_predicate record, :stale?
  end

  test "the slug lock is released even when the block raises" do
    assert_raises(RuntimeError) do
      CachedProfile.with_slug_lock("ada-lovelace") { raise "boom" }
    end

    # A second acquisition would block forever if the first leaked.
    assert_equal :ok, CachedProfile.with_slug_lock("ada-lovelace") { :ok }
  end

  test "different profiles do not contend for the same lock" do
    result = CachedProfile.with_slug_lock("ada-lovelace") do
      CachedProfile.with_slug_lock("grace-hopper") { :both_held }
    end

    assert_equal :both_held, result
  end
end
