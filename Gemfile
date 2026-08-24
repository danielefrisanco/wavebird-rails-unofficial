# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# CI runs a Ruby × Rails matrix (see gemfiles/ and .github/workflows/ci.yml).
# Each gemfiles/rails_X.Y.gemfile sets RAILS_VERSION and evaluates this file, so
# the Rails family is pinned in one place instead of being duplicated per
# gemfile. Unset (the normal local case) resolves the gemspec's own range.
rails_version = ENV.fetch("RAILS_VERSION", nil)
rails_requirement = rails_version ? ["~> #{rails_version}.0"] : [">= 7.1", "< 9"]

# Pinned together because the engine loads the controller/view stack and the
# async path loads ActiveJob/ActionCable; letting them drift apart resolves
# combinations no host would ever run.
gem "actioncable", *rails_requirement
gem "actionpack", *rails_requirement
gem "actionview", *rails_requirement
gem "activejob", *rails_requirement
gem "railties", *rails_requirement

group :development, :test do
  # Async delivery mode (decision #001) leans on ActiveJob (the poll job) and
  # Turbo/ActionCable (the broadcast). These are *optional* runtime requirements
  # for the host app, not gem dependencies — pinned above with the rest of the
  # Rails family only so the test suite can exercise the async path.
  #
  # Phase 8 system tests: a real dummy Rails app driven through headless Chrome,
  # so the Stimulus/Turbo browser glue (Phases 6a/6b) is exercised for real.
  gem "capybara", "~> 3.40"
  gem "dotenv", "~> 3.1"
  gem "puma", "~> 6.4"
  gem "rack-test", "~> 2.1"
  gem "rake", "~> 13.2"
  gem "rspec", "~> 3.13"
  gem "rspec-rails", "~> 7.1"
  # >= 1.90: the codebase uses `# rubocop:disable-next`, and `.rubocop.yml` sets
  # NewCops: enable. Together those mean a resolver free to pick an older RuboCop
  # can flag code a newer one accepts, and vice versa -- which is exactly how the
  # first CI run failed on a tree that was green locally (local 1.88.2, CI 1.90.0,
  # new cop Style/DirectiveScope). Floor it so local and CI agree.
  gem "rubocop", "~> 1.90", require: false
  gem "rubocop-rake", "~> 0.7", require: false
  gem "rubocop-rspec", "~> 3.6", require: false
  gem "selenium-webdriver", "~> 4.27"
  gem "simplecov", "~> 0.22", require: false
  gem "webmock", "~> 3.25"
  # Public API docs (Phase 9): `yard stats --list-undoc` must stay clean.
  gem "yard", "~> 0.9", require: false

  # The Stimulus/Turbo JS the dummy app loads via importmap (no Node build step),
  # present only so the system specs can drive a real Turbo Stream broadcast —
  # the gem itself depends on neither (decision #010).
  gem "stimulus-rails", "~> 1.3"
  gem "turbo-rails", "~> 2.0"
end
