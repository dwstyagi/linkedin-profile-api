namespace :linkedin do
  RECON_DIR = Rails.root.join("tmp", "recon")

  desc "Fetch one raw profile payload and save it for inspection: rake 'linkedin:recon[URL]'"
  task :recon, [ :url ] => :environment do |_task, args|
    url = args[:url].presence or abort "usage: rake 'linkedin:recon[https://www.linkedin.com/in/slug]'"

    parsed = LinkedIn::ProfileUrl.parse(url)
    puts "slug: #{parsed.public_identifier}"

    payload = LinkedIn::ProfileFetcher.new(parsed.public_identifier).call

    FileUtils.mkdir_p(RECON_DIR)
    path = RECON_DIR.join("#{parsed.public_identifier}.json")
    path.write(JSON.pretty_generate(payload))

    puts "top-level keys: #{payload.keys.sort.join(', ')}"
    puts "saved raw payload: #{path}"
    puts "now run: rake 'linkedin:normalize[#{path}]'"
  rescue LinkedIn::Error => e
    abort "#{e.class.name.demodulize}: #{e.message}"
  end

  desc "Call one Voyager path and print the result: rake 'linkedin:probe[identity/dash/profiles?q=memberIdentity&memberIdentity=slug]'"
  task :probe, [ :path ] => :environment do |_task, args|
    path = args[:path].presence or abort "usage: rake 'linkedin:probe[identity/dash/...]'"

    body = LinkedIn::Client.new.get(
      path, {}, accept: LinkedIn::ProfileFetcher::DASH_ACCEPT
    )

    included = Array(body["included"])
    puts "keys:     #{body.keys.sort.join(', ')}"
    puts "included: #{included.size} (#{included.filter_map { |e| e['$type'].to_s.split('.').last }.tally})"
    puts JSON.pretty_generate(body)[0, 4000]
  rescue LinkedIn::Error => e
    abort "#{e.class.name.demodulize}: #{e.message}"
  end

  desc "Re-run the normalizer against a saved payload: rake 'linkedin:normalize[PATH]'"
  task :normalize, [ :path ] => :environment do |_task, args|
    path = args[:path].presence or abort "usage: rake 'linkedin:normalize[tmp/recon/slug.json]'"
    payload = JSON.parse(File.read(path))
    slug = File.basename(path, ".json")

    data = LinkedIn::ProfileNormalizer.new(
      payload,
      public_identifier: slug,
      profile_url: "https://www.linkedin.com/in/#{slug}"
    ).call

    puts JSON.pretty_generate(data)

    # A quick read on how much of the profile actually came through, so gaps
    # in the mapping are obvious without diffing whole documents by eye.
    warn "\n--- coverage ---"
    data.each do |key, value|
      filled = value.is_a?(Array) ? value.any? : value.present?
      warn format("%-22s %s", key, filled ? "ok" : "empty")
    end
  end
end
