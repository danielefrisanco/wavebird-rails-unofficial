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

    RENDER_PATH = "/v1/render"

    # DOM id of a slot's <section>, shared by the view helper (which renders it)
    # and {DecisionPollJob} (which targets it when broadcasting), so the two can
    # never drift apart.
    #
    # @param position [String] slot position hint
    # @return [String]
    def slot_dom_id(position)
      "wavebird-slot-#{position}"
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

    # Browser-safe fields from a resolved {Types::Render} (blocking path). A fill
    # without a render block (renderer instructions omitted) collapses to just
    # +{ fill: true }+ once the nils are compacted away.
    def from_render(render_info)
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

    # Browser-safe fields from a decision (async path): the server builds
    # +frame_url+ from the +asset_token+ so the token stays server-side, and
    # takes dimensions/sponsor from the decision's creative.
    def from_decision(decision)
      creative = decision.creative
      {
        fill: true,
        frame_url: frame_url_for(decision.asset_token),
        width: creative&.width,
        height: creative&.height,
        sponsor_name: creative&.sponsor_name
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
