# frozen_string_literal: true

# Entry point matching the gem name, so both `require "wavebird-rails"` and
# `require "wavebird"` work (same pattern as turbo-rails). The hyphenated
# filename is required by the gem name; Naming/FileName is excluded for this
# file in .rubocop.yml.
require_relative "wavebird"
