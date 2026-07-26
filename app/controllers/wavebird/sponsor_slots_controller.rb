# frozen_string_literal: true

module Wavebird
  # Server-side sponsor-slot endpoint. Mirrors the Next.js/Express example route
  # from the integration brief: the browser POSTs slot context here, the secret
  # key stays server-only, and the response is browser-safe JSON for the Stimulus
  # controller / Turbo Frame.
  #
  # Fail-silent by contract (decision #003): it calls {Wavebird.client} (the
  # fail-silent facade), so a wavebird outage, timeout or API error surfaces as a
  # plain +{ "fill": false }+ with HTTP 200 — indistinguishable from an honest
  # no-fill. The host's chat flow is never disrupted by an ad failure.
  class SponsorSlotsController < ActionController::Base
    # Browser callers (fetch/XHR from the Stimulus controller) send JSON, not a
    # Rails form, so there is no CSRF token to verify; the endpoint reads no
    # cookies/session for auth and performs no state-changing host action.
    skip_forgery_protection

    # POST /wavebird/sponsor_slot
    def create
      placement = Wavebird.client.create_placement(**placement_args)
      render json: slot_payload(placement)
    end

    private

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

    def slot_params
      params.permit(:session_id, :job_type,
                    slot_hint: {}, overrides: {}, consent: {})
    end

    # Permits an arbitrary nested hash param and returns a plain Hash (or nil).
    def hash_param(key)
      value = slot_params[key]
      value&.to_h.presence
    end

    # Browser-safe projection of a placement. On no-fill (or any swallowed
    # failure, which the facade renders as a no-fill) this is just
    # +{ "fill" => false }+. On fill it exposes only what the hosted renderer
    # needs — never the secret key. The +frame_url+ embeds the asset token by
    # design: the hosted renderer authenticates the frame with it, so it is the
    # one piece of proof material that legitimately crosses to the browser.
    def slot_payload(placement)
      return { fill: false } unless placement.fill?

      render_info = placement.placement.render
      {
        fill: true,
        frame_url: render_info&.frame_url,
        script_url: render_info&.script_url,
        width: render_info&.width,
        height: render_info&.height,
        label_text: render_info&.label_text,
        sponsor_name: render_info&.sponsor_name
      }.compact
    end
  end
end
