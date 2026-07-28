# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  # Async delivery mode (decision #001) leans on ActiveJob (the poll job) and
  # Turbo/ActionCable (the broadcast). These are *optional* runtime requirements
  # for the host app, not gem dependencies — declared here only so the test suite
  # can exercise the async path.
  gem "activejob", ">= 7.1", "< 9"
  gem "dotenv", "~> 3.1"
  gem "rack-test", "~> 2.1"
  gem "rake", "~> 13.2"
  gem "rspec", "~> 3.13"
  gem "rubocop", "~> 1.75", require: false
  gem "rubocop-rake", "~> 0.7", require: false
  gem "rubocop-rspec", "~> 3.6", require: false
  gem "simplecov", "~> 0.22", require: false
  gem "webmock", "~> 3.25"
end
