class CreateLinkedInRequests < ActiveRecord::Migration[8.1]
  # An audit log of every call we make to LinkedIn.
  #
  # It backs the outbound rate limiter, and it is also the record of how the
  # session behaved over time: which endpoints answered, which were retired,
  # and at what request volume LinkedIn started refusing. That history is the
  # only way to answer "how many profiles can we actually fetch".
  def change
    create_table :linked_in_requests do |t|
      t.string :path, null: false
      t.integer :status
      t.string :outcome, null: false, default: "ok"

      t.datetime :created_at, null: false
    end

    add_index :linked_in_requests, :created_at
  end
end
