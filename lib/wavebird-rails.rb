# frozen_string_literal: true

# Entry point matching the gem name, so both `require "wavebird-rails"` and
# `require "wavebird"` work (same pattern as turbo-rails). The hyphenated
# filename is required by the gem name; Naming/FileName is excluded for this
# file in .rubocop.yml.
require_relative "wavebird"

# Load the Rails engine (routes, controller, helpers) when Rails is present.
# The plain `require "wavebird"` client path stays usable without Rails; this
# file is what a Rails app loads, so wiring the engine here keeps the two entry
# points cleanly separated.
begin
  require "action_controller/railtie"
  require "rails/engine"
rescue LoadError
  # Rails not available — client-only use. Nothing further to load.
else
  require_relative "wavebird/engine"
end
