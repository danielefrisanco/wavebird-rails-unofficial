# frozen_string_literal: true

require "cgi"

module Wavebird
  # Browser-safe projection of a fill — the single source of truth for what
  # crosses to the browser, shared by the blocking path
  # ({SponsorSlotsController}, from a {Types::PlacementResponse}) and the async
  # path ({DecisionPollJob}, from a {Types::Decision}).
  #
  # On no-fill (or any swallowed failure, which the facade renders as a no-fill)
  # this is +{ fill: false }+. On fill it exposes only what the hosted renderer
  # needs — **never** the secret key, and never the bare +asset_token+ as its own
  # field. The +frame_url+ embeds the asset token by design (+/v1/render/{token}+):
  # the hosted renderer authenticates the frame with it, so it is the one piece of
  # proof material that legitimately crosses to the browser (build prompt §5).
  #
  # The two API shapes differ: the blocking +/v1/placements+ response already
  # carries a resolved hosted-frame +render.frame_url+, whereas the async
  # +/v1/decisions/{slot_id}+ decision carries the raw +asset_token+ instead. For
  # the async case the server reconstructs +frame_url+ from the token using the
  # hosted renderer's own formula (+{api_base_url}/v1/render/{token}+ — see
  # +renderFrom+ in the render.js snapshot), so the +asset_token+ never leaves the
  # server and both paths present an identical boundary to the browser.
  module SlotPayload
    module_function

    # Path of the hosted frame endpoint, which takes the asset token as its last
    # segment (+/v1/render/{asset_token}+).
    RENDER_PATH = "/v1/render"

    # Path of the hosted renderer script, named in the payload so the renderer
    # has the same +script_url+ the blocking path's API response carries.
    RENDER_JS_PATH = "/v1/render.js"

    # The only render strategy the hosted renderer implements.
    HOSTED_FRAME = "hosted_frame"

    # Creative width the render script itself falls back to when the decision
    # carries no dimensions (+num(p.width)||300+ in +renderFrom+).
    DEFAULT_WIDTH = 300

    # Creative height the render script falls back to (+num(p.height)||250+).
    DEFAULT_HEIGHT = 250

    # DOM id of a slot's <section>, shared by the view helper (which renders it)
    # and {DecisionPollJob} (which targets it when broadcasting), so the two can
    # never drift apart.
    #
    # @param position [String] slot position hint
    # @return [String]
    def slot_dom_id(position)
      "wavebird-slot-#{position}"
    end

    # Turbo Stream a slot's async decision is delivered on, derived identically
    # by the view helper (which subscribes) and the endpoint (which broadcasts).
    #
    # **Scoped to the session, never to the position alone.** Upstream's decision
    # transport is a per-slot WebSocket — ticket, one message, close — so it is
    # scoped to a single caller by construction. A stream named only for the
    # position would be shared by every visitor rendering that position, and one
    # visitor's decision (including the +frame_url+ that embeds their
    # +asset_token+) would be broadcast to all of them, firing their beacons from
    # unrelated browsers. The session id restores upstream's per-caller scope.
    #
    # @param position [String] slot position hint
    # @param session_id [String] the slot's anonymous session id
    # @return [String]
    # @raise [ArgumentError] when +session_id+ is blank — an unscoped stream is a
    #   cross-session leak, so this fails loudly rather than degrading quietly
    def stream_name(position, session_id)
      token = session_id.to_s.strip
      raise ArgumentError, "wavebird async delivery requires a session_id (the Turbo Stream is scoped to it)" if
        token.empty?

      "wavebird_slot_#{position}_#{token}"
    end

    # @param source [Types::PlacementResponse, Types::Decision] a fill/no-fill
    #   carrier responding to +fill?+
    # @return [Hash] +{ fill: false }+ or the browser-safe render fields
    def call(source)
      return { fill: false } unless source.fill?

      # A placement response (blocking path) carries a resolved hosted-frame
      # +render+; a decision (async path) carries the raw +asset_token+ instead.
      # A placement response is only +fill?+ when its +placement+ is present
      # (see PlacementResponse#fill?), so +.placement+ is safe here.
      if source.respond_to?(:placement)
        from_render(source.placement.render)
      else
        from_decision(source)
      end
    end

    # Browser-safe fields from a resolved {Types::Render} (blocking path), shaped
    # as +{ placement: { render: … } }+ because that is exactly what the hosted
    # renderer reads, and what wavebird's own integration brief means by "returns
    # the wavebird JSON response to the browser".
    #
    # Its +startTurn+ resolves the endpoint's answer with
    # +placementFrom({decision: response})+, which reads +response.placement+;
    # +renderFrom(p)+ then takes +p.render.frame_url+, falling back to rebuilding
    # the URL from +p.asset_token+ — which this payload deliberately never
    # carries. A flat +frame_url+ satisfies no branch, so the renderer resolves
    # +null+ and silently paints nothing.
    #
    # A fill without a render block (renderer instructions omitted) collapses to
    # just +{ fill: true }+ once the nils are compacted away.
    def from_render(render_info)
      render = {
        strategy: render_info&.strategy || HOSTED_FRAME,
        frame_url: render_info&.frame_url,
        script_url: render_info&.script_url,
        media_type: render_info&.media_type,
        width: render_info&.width,
        height: render_info&.height,
        aspect_ratio: render_info&.aspect_ratio,
        label_text: render_info&.label_text,
        sponsor_name: render_info&.sponsor_name,
        click_url: render_info&.click_url
      }.compact
      render.key?(:frame_url) ? { fill: true, placement: { render: render } } : { fill: true }
    end

    # Browser-safe fields from a decision (async path): the server builds
    # +frame_url+ from the +asset_token+ so the token stays server-side, and
    # takes dimensions/sponsor from the decision's creative. Shaped exactly like
    # the blocking path so the hosted renderer sees one contract either way —
    # this mirrors the render script's own +renderFrom+ fallback, which is what
    # it would have built from the token had we sent it.
    def from_decision(decision)
      frame_url = frame_url_for(decision.asset_token)
      return { fill: true } if frame_url.nil?

      { fill: true, placement: { render: decision_render(decision, frame_url) } }
    end

    # The render block the render script would have built for itself from the
    # asset token (+renderFrom+'s fallback branch), assembled server-side so the
    # token never crosses.
    def decision_render(decision, frame_url)
      creative = decision.creative
      width = creative&.width || DEFAULT_WIDTH
      height = creative&.height || DEFAULT_HEIGHT
      {
        strategy: HOSTED_FRAME,
        frame_url: frame_url,
        script_url: "#{Wavebird.configuration.api_base_url}#{RENDER_JS_PATH}",
        width: width, height: height, aspect_ratio: "#{width}/#{height}",
        label_text: "Sponsored", sponsor_name: creative&.sponsor_name
      }.compact
    end

    # Reconstructs the hosted-frame URL from an asset token, mirroring the render
    # script's +renderFrom+ (+{origin}/v1/render/{encoded token}+).
    def frame_url_for(asset_token)
      return if asset_token.nil?

      base = Wavebird.configuration.api_base_url
      # Path-segment-safe encoding (spaces -> %20, not +), matching the client's
      # own URL building (Client#encode) so async and blocking agree.
      "#{base}#{RENDER_PATH}/#{CGI.escapeURIComponent(asset_token)}"
    end
  end
end
