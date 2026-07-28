# frozen_string_literal: true

# A minimal in-memory Rails application that mounts the wavebird engine, so
# controller behavior can be exercised through the real routing/rendering stack
# with rack-test — without a full spec/dummy directory or rspec-rails (those
# arrive with the Capybara system tests in Phase 8).
require "rails"
require "rack/test"
require "tmpdir"

# ActiveJob is an optional runtime dependency of the gem (async delivery mode,
# decision #001). Load it here with the test adapter so async-mode specs can
# assert enqueues; a client-only host that never uses async would not load it.
require "active_job"
ActiveJob::Base.queue_adapter = :test

module WavebirdSpec
  # An empty throwaway root, so the test application does NOT adopt the gem's own
  # config/routes.rb as its application routes (the gem is developed in place, so
  # the engine root == repo root; sharing that routes file would draw the
  # engine's routes twice and collide on the route name).
  APP_ROOT = Dir.mktmpdir("wavebird-spec-app")

  # Built once and memoized; the engine and its routes are process-global.
  class Application < ::Rails::Application
    config.root = APP_ROOT
    config.eager_load = false
    config.consider_all_requests_local = true
    config.hosts.clear # rack-test posts as example.org; allow any host in the test app
    config.secret_key_base = "wavebird-spec-secret-key-base"
    config.logger = Logger.new(File::NULL)
    config.eager_load_paths.clear

    routes.append do
      mount Wavebird::Engine => "/wavebird"
    end
  end
end

# Boot once for the whole suite.
WavebirdSpec::Application.initialize! unless WavebirdSpec::Application.initialized?

# Shared context for engine request specs: gives examples the mounted Rack app
# and rack-test helpers, and points requests at the engine's routes.
RSpec.shared_context "with the wavebird engine mounted" do
  include Rack::Test::Methods

  # @return [WavebirdSpec::Application] the Rack app under test
  def app
    WavebirdSpec::Application
  end

  # Convenience: POST a JSON body to a path on the mounted engine.
  def post_json(path, payload = {})
    post path, payload.to_json, "CONTENT_TYPE" => "application/json"
  end
end
