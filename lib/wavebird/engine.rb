# frozen_string_literal: true

require "action_controller/railtie"
require "rails/engine"
require_relative "../wavebird"

module Wavebird
  # Rails engine that mounts the server-side sponsor-slot endpoint and exposes
  # the view helpers. Isolated namespace so the host app's routes, helpers and
  # controllers never collide with the gem's.
  #
  # Mount it in the host's +config/routes.rb+:
  #
  #   mount Wavebird::Engine => "/wavebird"
  #
  # which gives +POST /wavebird/sponsor_slot+ (route name
  # +wavebird.sponsor_slot_path+). The engine's own +config/routes.rb+ defines
  # that single route.
  class Engine < ::Rails::Engine
    isolate_namespace Wavebird
  end
end
