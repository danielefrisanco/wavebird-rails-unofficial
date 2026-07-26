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
    # @param session_id [String, nil] anonymous session id sent with the slot
    #   request; see {SessionId#wavebird_session_id}
    # @param endpoint [String] the engine's sponsor-slot path
    #   (+wavebird.sponsor_slot_path+)
    # @param position [String] slot position hint, also used to build the id
    # @param html_options [Hash] extra HTML attributes merged onto the section
    # @return [ActiveSupport::SafeBuffer]
    def wavebird_slot(endpoint:, session_id: nil, position: "below", **html_options)
      data = {
        controller: "wavebird",
        wavebird_endpoint: endpoint,
        wavebird_session_id_value: session_id,
        wavebird_position_value: position
      }.compact

      content_tag(:section, "",
                  { id: "wavebird-slot-#{position}", hidden: true,
                    data: data }.merge(html_options))
    end
  end
end
