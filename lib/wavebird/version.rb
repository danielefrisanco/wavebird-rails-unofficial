# frozen_string_literal: true

module Wavebird
  # Gem version. Sent upstream as part of the +User-Agent+/wrapper version
  # (+wavebird-rails/{VERSION}+) so wavebird can attribute traffic to this Rails
  # port.
  #
  # **This tracks the upstream SDK version, not an independent cadence of ours**
  # (Daniele's decision, 2026-08-11): the gem is a port, and shipping the version
  # of the thing it ports says which contract it implements. Bump it when the
  # ported SDK version changes, not when this gem changes.
  VERSION = "0.1.5"
end
