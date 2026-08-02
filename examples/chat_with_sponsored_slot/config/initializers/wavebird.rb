# frozen_string_literal: true

# Server-side configuration. This file must stay under config/ — never under
# app/assets or app/javascript, where the secret key would become reachable from
# the browser. The gem raises Wavebird::ConfigurationError at boot if it is.
Wavebird.configure do |config|
  # sk_test_... (sandbox), sk_dry_... (production dry run) or sk_live_...
  # A callable is also accepted, and is resolved immediately before each request
  # — useful when keys are rotated by a secrets manager.
  config.secret_key = Rails.application.credentials.dig(:wavebird, :secret_key)

  # Your wavebird project id (wbproj_...).
  config.client_id = Rails.application.credentials.dig(:wavebird, :client_id)

  # Warnings only. The gem never writes the secret key or an asset token here.
  config.logger = Rails.logger

  # Optional: the shape you want the slot auctioned for. Sent with every
  # placement unless a call overrides it.
  config.default_slot_hint = { position: "below", max_width: 728, max_height: 90 }

  # Optional: report every swallowed failure to your error tracker. The gem is
  # fail-silent by design, so this is how you see that wavebird was unreachable.
  config.on_error = ->(error) { Rails.error.report(error, handled: true) }
end
