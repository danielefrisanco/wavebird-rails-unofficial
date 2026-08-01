# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  # Async delivery mode (decision #001) leans on ActiveJob (the poll job) and
  # Turbo/ActionCable (the broadcast). These are *optional* runtime requirements
  # for the host app, not gem dependencies — declared here only so the test suite
  # can exercise the async path.
  gem "activejob", ">= 7.1", "< 9"
  # Phase 8 system tests: a real dummy Rails app driven through headless Chrome,
  # so the Stimulus/Turbo browser glue (Phases 6a/6b) is exercised for real.
  gem "capybara", "~> 3.40"
  gem "dotenv", "~> 3.1"
  gem "puma", "~> 6.4"
  gem "rack-test", "~> 2.1"
  gem "rake", "~> 13.2"
  gem "rspec", "~> 3.13"
  gem "rspec-rails", "~> 7.1"
  gem "rubocop", "~> 1.75", require: false
  gem "rubocop-rake", "~> 0.7", require: false
  gem "rubocop-rspec", "~> 3.6", require: false
  gem "selenium-webdriver", "~> 4.27"
  gem "simplecov", "~> 0.22", require: false
  gem "webmock", "~> 3.25"

  # Optional runtime requirements of async delivery mode (decision #010) and the
  # Stimulus JS the dummy app loads via importmap (no Node build step). Present
  # here only so the system specs can drive a real Turbo Stream broadcast — the
  # gem itself still depends on neither.
  gem "actioncable", ">= 7.1", "< 9"
  gem "stimulus-rails", "~> 1.3"
  gem "turbo-rails", "~> 2.0"
end
