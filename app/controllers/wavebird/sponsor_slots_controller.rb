# frozen_string_literal: true

module Wavebird
  # Server-side sponsor-slot endpoint. Mirrors the Next.js/Express example route
  # from the integration brief: the browser POSTs slot context here, the secret
  # key stays server-only, and the response is browser-safe JSON for the Stimulus
  # controller.
  #
  # Fail-silent by contract (decision #003): it calls {Wavebird.client} (the
  # fail-silent facade), so a wavebird outage, timeout or API error surfaces as a
  # plain +{ "fill": false }+ with HTTP 200 — indistinguishable from an honest
  # no-fill. The host's chat flow is never disrupted by an ad failure.
  #
  # Two delivery modes (decision #001):
  #
  # - **blocking** (default): a single +create_placement+ call waits +wait_ms+ for
  #   the decision and returns the browser-safe payload inline.
  # - **async** (opt-in, +mode: "async"+): a non-blocking +create_job+ enqueues
  #   {DecisionPollJob}, which long-polls server-side and reveals the slot over a
  #   Turbo Stream — zero added chat latency. Async needs Turbo/ActionCable in the
  #   host; when it is absent (or the job could not be created) the endpoint
  #   gracefully falls back to the blocking path so the slot still fills.
  class SponsorSlotsController < ActionController::Base
    # Browser callers (fetch/XHR from the Stimulus controller) send JSON, not a
    # Rails form, so there is no CSRF token to verify; the endpoint reads no
    # cookies/session for auth and performs no state-changing host action.
    skip_forgery_protection

    # POST /wavebird/sponsor_slot
    def create
      if async_requested? && async_available?
        async_response
      else
        blocking_response
      end
    end

    private

    # The synchronous path: place, wait, and return the browser-safe payload.
    def blocking_response
      placement = Wavebird.client.create_placement(**placement_args)
      render json: SlotPayload.call(placement)
    end

    # The async path: create a job (non-blocking), enqueue the poller, and tell
    # the browser the decision is pending — it arrives later over the Turbo
    # Stream. Falls back to blocking when the job could not be created (the facade
    # fails silently to +nil+) so the slot still resolves.
    def async_response
      job = Wavebird.client.create_job(**job_args)
      return blocking_response if job.nil? || job.slot_ids.empty?

      DecisionPollJob.perform_later(job.slot_ids.first, stream_name)
      render json: { pending: true }
    end

    def async_requested?
      slot_params[:mode].to_s == "async"
    end

    # Async needs Turbo Streams (over ActionCable) and ActiveJob in the host app.
    # Both are *optional* dependencies: async mode is opt-in, and their absence
    # degrades to the blocking path with a one-line warning rather than a crash —
    # the standard "graceful fallback" posture for a gem leaning on optional Rails
    # components. The job is required lazily here (it lives off the autoload path)
    # so a client-only / minimal app never loads ActiveJob.
    def async_available?
      if defined?(Turbo::StreamsChannel) && defined?(ActiveJob::Base)
        require "wavebird/decision_poll_job"
        return true
      end

      Wavebird.configuration.logger&.warn(
        "[wavebird] async mode requested but Turbo Streams / ActiveJob is not available; " \
        "falling back to blocking. Add turbo-rails + activejob + an ActionCable adapter to enable it."
      )
      false
    end

    # The Turbo Stream the browser subscribed to (see {SlotHelper#wavebird_slot}).
    # Defaults to a per-position stream when the client does not send one.
    def stream_name
      slot_params[:stream_name].presence || "wavebird_slot_#{slot_params[:position].presence || 'below'}"
    end

    # Whitelisted, browser-supplied slot context merged over the configured
    # defaults. The user's raw prompt is deliberately not accepted here (privacy
    # §4): semantic targeting is opt-in and configured server-side, not driven by
    # untrusted request params.
    def placement_args
      {
        session_id: slot_params[:session_id],
        job_type: slot_params[:job_type].presence || "chat",
        slot_hint: hash_param(:slot_hint),
        overrides: hash_param(:overrides),
        consent: hash_param(:consent)
      }.compact
    end

    # +create_job+ takes the same context minus the placement-only +consent+ arg.
    def job_args
      placement_args.except(:consent)
    end

    def slot_params
      params.permit(:session_id, :job_type, :mode, :stream_name, :position,
                    slot_hint: {}, overrides: {}, consent: {})
    end

    # Permits an arbitrary nested hash param and returns a plain Hash (or nil).
    def hash_param(key)
      value = slot_params[key]
      value&.to_h.presence
    end
  end
end
