# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"

# Unit + request specs (fast; no browser). Excludes spec/system, which needs its
# own process: only one Rails application can exist per process, and the system
# specs boot the full spec/dummy host app rather than the rack-test one.
RSpec::Core::RakeTask.new(:spec) do |task|
  task.exclude_pattern = "spec/system/**/*_spec.rb"
end

namespace :spec do
  desc "Run the Capybara system specs against spec/dummy in headless Chrome"
  RSpec::Core::RakeTask.new(:system) do |task|
    task.pattern = "spec/system/**/*_spec.rb"
    # Selects the spec/dummy host app over the rack-test one, and skips the
    # coverage gate: this process exercises the browser glue, not lib/.
    task.rspec_opts = "--no-color"
    ENV["WAVEBIRD_SYSTEM_SPECS"] = "1"
    ENV["WAVEBIRD_SKIP_COVERAGE_GATE"] = "1"
  end
end

RuboCop::RakeTask.new

# Deliberately not a diff: what matters is that it moved. The renderer is served,
# not versioned -- no version to pin, and the public changelog did not mention the
# change that broke the gem (plan v3) -- so refetching is the only defence.
def render_js_drift_message(snapshot, stored_bytes, live_bytes)
  <<~MSG
    wavebird's hosted render.js has CHANGED since #{File.basename(snapshot)}.

      snapshot: #{stored_bytes} bytes
      live:     #{live_bytes} bytes

    Save it as docs/upstream/render-js-snapshot-<today>.js, keep the old one, and
    run the suite: render_js_contract_spec compares the gates the live renderer
    enforces against the ones the test stand-in implements, and will name any new
    precondition the gem does not satisfy.

    Do not skip this. A gate added upstream makes every turn fail silently --
    no request, no error, nothing in the console.
  MSG
end

# The snapshot carries a provenance header the served file does not, so compare
# only the payload. Read binary: the served file contains a NUL byte, which also
# makes grep treat it as binary and report nothing.
def snapshot_payload(path)
  File.read(path, encoding: "BINARY").sub(%r{\A(?://[^\n]*\n)+}, "")
end

desc "Refetch wavebird's hosted render.js and report whether our snapshot is stale"
task :render_js_drift do
  require "net/http"
  require "digest"

  url = URI("https://api.wavebird.ai/v1/render.js")
  snapshot = Dir.glob("docs/upstream/render-js-snapshot-*.js").max
  abort("no render.js snapshot in docs/upstream/") if snapshot.nil?

  live = begin
    Net::HTTP.get_response(url).body
  rescue StandardError => e
    abort("could not fetch #{url}: #{e.class}: #{e.message}")
  end

  stored = snapshot_payload(snapshot)

  if stored == live.dup.force_encoding("BINARY")
    puts "render.js unchanged since #{File.basename(snapshot)} (#{live.bytesize} bytes)"
    next
  end

  # Deliberately not a diff: what matters is that it moved. The renderer is
  # served, not versioned -- no version to pin, and the public changelog did not
  # mention the change that broke the gem (plan v3), so refetching is the only
  # defence. Refresh the snapshot and let render_js_contract_spec say what broke.
  abort(render_js_drift_message(snapshot, stored.bytesize, live.bytesize))
end

desc "Fail unless every public API object carries YARD documentation"
task :yard_coverage do
  require "open3"
  stats, status = Open3.capture2e("bundle", "exec", "yard", "stats", "--list-undoc")
  abort(stats) unless status.success?

  puts stats
  abort("Public API documentation is incomplete (see the list above).") unless stats.include?("100.00% documented")
end

task default: %i[spec spec:system rubocop yard_coverage]
