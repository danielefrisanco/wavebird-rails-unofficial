# frozen_string_literal: true

# Minimal host application for the Phase 8 system tests. It is a *real* Rails
# app — routes, views, Stimulus, Turbo Streams over ActionCable — so the browser
# glue shipped by this gem (Phases 6a/6b) is exercised the way a host would use
# it, rather than simulated.
#
# Kept deliberately small: no database, no asset pipeline build step. JavaScript
# is served as plain ES modules through an importmap (see the layout), which is
# also the setup INSTALL.md documents first.
require "rails"
require "action_controller/railtie"
require "action_view/railtie"
require "active_job/railtie"
require "action_cable/engine"
require "turbo-rails"
require "stimulus-rails"
require "wavebird-rails"

module Dummy
  # The host application under test.
  class Application < ::Rails::Application
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.consider_all_requests_local = true
    config.hosts.clear # Capybara serves on a random 127.0.0.1 port
    config.secret_key_base = "wavebird-dummy-secret-key-base"
    config.logger = Logger.new(File::NULL)
    config.active_job.queue_adapter = :test

    # The session-id concern stores an anonymous id in the session, so the host
    # needs a session store (a full `rails new` app has one by default; this
    # trimmed-down config must opt in).
    config.session_store :cookie_store, key: "_wavebird_dummy_session"
    config.middleware.use ActionDispatch::Cookies
    config.middleware.use config.session_store, config.session_options

    # In-process pub/sub: real ActionCable, no Redis, no external process.
    config.action_cable.cable = { "adapter" => "async" }
    config.action_cable.disable_request_forgery_protection = true

    # Serve the local render.js stand-in and the dummy's own files.
    config.public_file_server.enabled = true

    # JavaScript is served by explicit routes (see config/routes.rb) straight
    # from where it really lives — the gem's own app/javascript and the
    # stimulus/turbo gems — so nothing is vendored, copied or machine-specific,
    # and the specs exercise the exact files the gem ships.
  end
end
