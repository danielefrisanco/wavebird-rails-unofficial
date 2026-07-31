# frozen_string_literal: true

require "rails/railtie"
require_relative "boot_check"

module Wavebird
  # Boot-time security wiring (build prompt §4). Kept separate from {Engine} —
  # which subclasses +Rails::Railtie+ and could host this — so the guard runs for
  # every Rails host whether or not the engine is mounted, and so the file layout
  # matches the one the build prompt specifies.
  #
  # Registers a single initializer, +wavebird.boot_check+, which fails loudly if
  # the gem's server-side Ruby has been placed on the asset load path. See
  # {BootCheck} for what is checked and what is deliberately allowed.
  class Railtie < ::Rails::Railtie
    initializer "wavebird.boot_check" do |app|
      BootCheck.run(app)
    end
  end
end
