# frozen_string_literal: true

require "simplecov"
# Keep the two suites' coverage runs from overwriting each other's report.
SimpleCov.coverage_dir("coverage/system") if ENV["WAVEBIRD_SKIP_COVERAGE_GATE"] == "1"
SimpleCov.start do
  enable_coverage :branch
  add_filter "/spec/" # includes spec/dummy — the host app is a fixture, not gem code
  # 100% on lib/wavebird/* is the target (build plan §6), enforced by the unit +
  # request suite. The system specs run as a separate process that drives the
  # browser rather than lib/, so the gate would be meaningless there.
  minimum_coverage line: 100, branch: 100 unless ENV["WAVEBIRD_SKIP_COVERAGE_GATE"] == "1"
end

require "dotenv"
Dotenv.load(".env.test")

require "webmock/rspec"
# Present in any real install via the railties dependency; load it explicitly so
# specs exercise the client's instrumentation path (build plan §4).
require "active_support"
require "active_support/notifications"
require "wavebird-rails"

WebMock.disable_net_connect!

# Only one Rails application may exist per process, so the rack-test app
# (support/rails_app.rb) and the full spec/dummy host app used by the system
# specs cannot both boot. System specs therefore run as their own process — see
# `rake spec:system` — and this flag selects which app the support files build.
WAVEBIRD_SYSTEM_SPECS = ENV["WAVEBIRD_SYSTEM_SPECS"] == "1"

# The system-test harness boots spec/dummy, Capybara and a browser; each spec in
# spec/system requires it explicitly, keeping the fast unit suite free of that
# startup cost.
skip_support = [File.join(__dir__, "support", "system_tests.rb")]
skip_support << File.join(__dir__, "support", "rails_app.rb") if WAVEBIRD_SYSTEM_SPECS
Dir[File.join(__dir__, "support", "**", "*.rb")].reject { |f| skip_support.include?(f) }
                                                .each { |file| require file }

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
