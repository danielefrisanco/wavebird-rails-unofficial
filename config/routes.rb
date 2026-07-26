# frozen_string_literal: true

# The engine's isolated routes. Mounted by the host at a prefix of its choice
# (conventionally +/wavebird+), so the full path is +POST /wavebird/sponsor_slot+.
Wavebird::Engine.routes.draw do
  post "sponsor_slot", to: "sponsor_slots#create", as: :sponsor_slot
end
