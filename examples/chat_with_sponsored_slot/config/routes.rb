# frozen_string_literal: true

Rails.application.routes.draw do
  # Mount the engine at any prefix you like. This gives you
  # POST /wavebird/sponsor_slot, addressable in views as
  # wavebird.sponsor_slot_path — the endpoint the browser posts slot context to.
  mount Wavebird::Engine => "/wavebird"

  resource :chat, only: :show
end
