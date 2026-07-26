# frozen_string_literal: true

require "simplecov"
SimpleCov.start do
  enable_coverage :branch
  add_filter "/spec/"
  # 100% on lib/wavebird/* is the target (build plan §6); ratchet as code lands.
  minimum_coverage line: 100, branch: 100
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

Dir[File.join(__dir__, "support", "**", "*.rb")].each { |file| require file }

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
