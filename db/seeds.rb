# Seeds one profile straight into the cache from the test fixture.
#
# This makes the full request path — auth, URL parsing, cache lookup,
# serialization — demoable end to end without a LinkedIn session, which is
# useful both for local development and for anyone reviewing the API who does
# not have credentials.
#
#   bin/rails db:seed
#   curl -H "X-API-Key: $API_KEY" \
#     "http://localhost:3000/api/v1/profile?url=https://www.linkedin.com/in/ada-lovelace"

SLUG = "ada-lovelace".freeze
FIXTURE = Rails.root.join("test", "fixtures", "files", "dash_profile.json")

payload = JSON.parse(FIXTURE.read)

data = LinkedIn::ProfileNormalizer.new(
  payload,
  public_identifier: SLUG,
  profile_url: "https://www.linkedin.com/in/#{SLUG}"
).call

CachedProfile.store!(
  public_identifier: SLUG,
  profile_url: "https://www.linkedin.com/in/#{SLUG}",
  data: data,
  raw_payload: payload
)

puts "Seeded #{SLUG}. #{CachedProfile.count} profile(s) cached."
