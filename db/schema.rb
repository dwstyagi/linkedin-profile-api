# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_28_044528) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "cached_profiles", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "data", default: {}, null: false
    t.datetime "fetched_at", null: false
    t.string "profile_url", null: false
    t.string "public_identifier", null: false
    t.jsonb "raw_payload", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["fetched_at"], name: "index_cached_profiles_on_fetched_at"
    t.index ["public_identifier"], name: "index_cached_profiles_on_public_identifier", unique: true
  end

  create_table "linked_in_requests", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "outcome", default: "ok", null: false
    t.string "path", null: false
    t.integer "status"
    t.index ["created_at"], name: "index_linked_in_requests_on_created_at"
  end
end
