class CreateCachedProfiles < ActiveRecord::Migration[8.1]
  def change
    create_table :cached_profiles do |t|
      # LinkedIn's own slug for the profile, e.g. "satyanadella" from /in/satyanadella.
      t.string :public_identifier, null: false
      t.string :profile_url, null: false

      # The normalized response we serve to clients.
      t.jsonb :data, null: false, default: {}

      # The untouched upstream payload, kept so the normalizer can be reworked
      # offline when LinkedIn changes shape, without spending more requests.
      t.jsonb :raw_payload, null: false, default: {}

      t.datetime :fetched_at, null: false

      t.timestamps
    end

    add_index :cached_profiles, :public_identifier, unique: true
    add_index :cached_profiles, :fetched_at
  end
end
