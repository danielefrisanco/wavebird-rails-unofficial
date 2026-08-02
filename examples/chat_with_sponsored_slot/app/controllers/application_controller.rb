# frozen_string_literal: true

# The two lines a host app adds once to use wavebird's view helpers.
class ApplicationController < ActionController::Base
  # The engine isolates its namespace, so its view helpers (wavebird_slot,
  # wavebird_render_script_tag) are not mixed into host views automatically.
  helper Wavebird::SlotHelper

  # Provides wavebird_session_id: a stable, anonymous "sess_..." token per
  # browser session, exposed to views as a helper. It is deliberately not a user
  # id — wavebird never receives anything that identifies your users. Apps that
  # already have their own anonymous session id can skip this and pass that
  # value to wavebird_slot instead.
  include Wavebird::SessionId
end
