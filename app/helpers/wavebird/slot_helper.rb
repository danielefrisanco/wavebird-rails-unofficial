# frozen_string_literal: true

module Wavebird
  # View helpers for placing a sponsor slot on a page, mirroring the hosted
  # renderer's plain-HTML contract (see the integration brief and the live
  # +render.js+ snapshot in +docs/upstream/+) in Hotwire-idiomatic form.
  #
  # The hosted renderer (+render.js+) owns the slot element: it mounts an iframe
  # into it via +target.replaceChildren+ and toggles +target.hidden+. So the
  # slot is a *plain* element decorated with a Stimulus controller — not a Turbo
  # Frame, which would fight the renderer for the element's lifecycle
  # (decision #006).
  module SlotHelper
    # URL path of the hosted renderer script, resolved against the configured
    # +api_base_url+.
    RENDER_JS_PATH = "/v1/render.js"

    # Emits the hosted-renderer +<script>+ tag exactly once per rendered page,
    # no matter how many times it is called (a page may declare several slots).
    #
    # @return [ActiveSupport::SafeBuffer, nil] the tag on first call, +nil+ after
    def wavebird_render_script_tag
      return if @wavebird_render_script_emitted

      @wavebird_render_script_emitted = true
      javascript_include_tag("#{Wavebird.configuration.api_base_url}#{RENDER_JS_PATH}",
                             async: true, defer: true)
    end

    # Renders a hidden sponsor slot: a plain +<section>+ carrying the endpoint
    # the renderer POSTs to and the Stimulus hook that wraps the AI turn. Starts
    # +hidden+ and is revealed by the renderer on fill (build prompt §3.5).
    #
    # For **async delivery mode** (+async: true+) it also subscribes the slot to a
    # Turbo Stream, so {DecisionPollJob} can reveal it out-of-band once the
    # server-side long-poll resolves. The subscription is only emitted when
    # +turbo_stream_from+ is available (turbo-rails loaded) — async mode is an
    # optional feature; without it the slot still works in the blocking default.
    #
    # @param session_id [String, nil] anonymous session id sent with the slot
    #   request; see {SessionId#wavebird_session_id}
    # @param endpoint [String] the engine's sponsor-slot path
    #   (+wavebird.sponsor_slot_path+)
    # @param position [String] slot position hint, also used to build the id
    # @param async [Boolean] subscribe the slot to its Turbo Stream for async mode
    # @param html_options [Hash] extra HTML attributes merged onto the section
    # @return [ActiveSupport::SafeBuffer]
    # @raise [ArgumentError] when +async: true+ without a +session_id+ — the
    #   stream is scoped to the session, and an unscoped one would deliver this
    #   visitor's decision to every other visitor (see {SlotPayload.stream_name})
    def wavebird_slot(endpoint:, session_id: nil, position: "below", async: false, **html_options)
      stream = (SlotPayload.stream_name(position, session_id) if async)
      section = content_tag(:section, "",
                            { id: SlotPayload.slot_dom_id(position), hidden: true,
                              data: wavebird_slot_data(endpoint:, session_id:, position:,
                                                       async:) }.merge(html_options))
      return section unless async

      safe_join([wavebird_stream_subscription(stream), section].compact)
    end

    private

    # Stimulus hook plus the values the controller reads. +mode+ asks the endpoint
    # for async delivery and is omitted in the blocking default.
    #
    # The stream name is deliberately **not** among these. It is derived
    # server-side on both ends from position + session id
    # ({SlotPayload.stream_name}); sending it to the browser and back would let a
    # client choose which stream the server broadcasts onto.
    def wavebird_slot_data(endpoint:, session_id:, position:, async:)
      {
        controller: "wavebird",
        wavebird_endpoint: endpoint,
        wavebird_session_id_value: session_id,
        wavebird_position_value: position,
        wavebird_mode_value: ("async" if async)
      }.compact
    end

    # Turbo Stream subscription for the slot, or +nil+ when turbo-rails is not
    # loaded (async mode is optional; the caller degrades to the blocking path).
    def wavebird_stream_subscription(stream)
      return unless respond_to?(:turbo_stream_from)

      turbo_stream_from(stream)
    end
  end
end
