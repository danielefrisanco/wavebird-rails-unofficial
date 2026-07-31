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

task default: %i[spec spec:system rubocop]
