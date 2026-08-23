# frozen_string_literal: true

RSpec.describe Wavebird::SlotPayload do
  after { Wavebird.reset_configuration! }

  # Plan v3 item A, and the half that needs no JavaScript at all. The hosted
  # renderer's renderPlacement -- which the async reveal calls directly (#009) --
  # resolves consent as `options.authoritative_consent || p.authoritative_consent`,
  # so a payload carrying its own consent satisfies the gate without the
  # broadcast threading anything through the browser.
  describe "the consent carried in the payload" do
    let(:future) { (Time.now.to_f * 1000).to_i + 60_000 }
    let(:response) do
      Wavebird::Types::PlacementResponse.from_api(
        "status" => "ready",
        "placement" => { "asset_token" => "at_secret",
                         "render" => { "frame_url" => "https://api.wavebird.ai/v1/render/at_secret" } },
        "decision" => { "fill" => true }
      )
    end

    it "nests the consent inside the placement, where renderPlacement looks for it" do
      Wavebird.configure do |c|
        c.authoritative_consent = -> { { lifecycle_state: "granted", expires_at_ms: future } }
      end

      payload = described_class.call(response)

      expect(payload[:placement][:authoritative_consent])
        .to include(lifecycle_state: "granted", revision: 1)
      # Beside the render block, not inside it: renderFrom reads p.render and
      # would ignore anything buried there.
      expect(payload[:placement][:render]).not_to have_key(:authoritative_consent)
    end

    it "leaves the payload untouched when no consent is configured" do
      payload = described_class.call(response)

      expect(payload[:placement]).not_to have_key(:authoritative_consent)
      expect(payload[:fill]).to be(true)
    end

    it "does not attach consent to a no-fill" do
      Wavebird.configure do |c|
        c.authoritative_consent = -> { { lifecycle_state: "granted", expires_at_ms: future } }
      end
      empty = Wavebird::Types::PlacementResponse.from_api("status" => "no_fill", "placement" => nil)

      expect(described_class.call(empty)).to eq(fill: false)
    end
  end

  describe "from a placement response (blocking path)" do
    let(:response) do
      Wavebird::Types::PlacementResponse.from_api(
        "status" => "ready",
        "placement" => {
          "asset_token" => "at_secret",
          "render" => {
            "strategy" => "hosted_frame",
            "frame_url" => "https://api.wavebird.ai/v1/render/at_secret",
            "script_url" => "https://api.wavebird.ai/v1/render.js",
            "width" => 728, "height" => 90, "label_text" => "Sponsored", "sponsor_name" => "Acme"
          }
        },
        "decision" => { "fill" => true }
      )
    end

    # Shaped as { placement: { render: … } } because that is what the hosted
    # renderer reads: startTurn resolves placementFrom({decision: response}),
    # which looks for response.placement, then renderFrom takes p.render.
    it "projects the browser-safe render fields under placement.render" do
      expect(described_class.call(response)).to eq(
        fill: true,
        placement: { render: {
          strategy: "hosted_frame",
          frame_url: "https://api.wavebird.ai/v1/render/at_secret",
          script_url: "https://api.wavebird.ai/v1/render.js",
          width: 728, height: 90, label_text: "Sponsored", sponsor_name: "Acme"
        } }
      )
    end

    # fill: true with nothing attached describes a state the renderer cannot act
    # on -- startTurn discards a placement without a render and clears the slot --
    # so the payload says no-fill rather than shipping a shape that paints
    # nothing (the #017 class of bug).
    it "reports a fill with no render block as a no-fill" do
      renderless = Wavebird::Types::PlacementResponse.from_api(
        "status" => "ready",
        "placement" => { "asset_token" => "at_secret" },
        "decision" => { "fill" => true }
      )

      expect(described_class.call(renderless)).to eq(fill: false)
    end

    it "reports a render block with a blank frame_url as a no-fill" do
      blank = Wavebird::Types::PlacementResponse.from_api(
        "status" => "ready",
        "placement" => { "asset_token" => "at_secret", "render" => { "frame_url" => "  " } },
        "decision" => { "fill" => true }
      )

      expect(described_class.call(blank)).to eq(fill: false)
    end

    # Deliberately less strict than upstream's normalizeWavebirdPlacement, which
    # drops a render block missing any of strategy/script_url/media_type/width/
    # height/aspect_ratio/label_text. The hosted renderer does not use that
    # helper: renderFrom needs only frame_url and derives the rest, so dropping a
    # partial block here would hide an ad the renderer could paint.
    it "forwards a render block carrying only a frame_url" do
      sparse = Wavebird::Types::PlacementResponse.from_api(
        "status" => "ready",
        "placement" => { "asset_token" => "at_secret",
                         "render" => { "frame_url" => "https://api.wavebird.ai/v1/render/at_secret" } },
        "decision" => { "fill" => true }
      )

      expect(described_class.call(sparse)).to eq(
        fill: true,
        placement: { render: { strategy: "hosted_frame",
                               frame_url: "https://api.wavebird.ai/v1/render/at_secret" } }
      )
    end
  end

  describe "from a decision (async path)" do
    let(:decision) do
      Wavebird::Types::Decision.from_api(
        "slot_id" => "slot_1", "status" => "ready", "fill" => true,
        "asset_token" => "at secret/token",
        "creative" => { "width" => 300, "height" => 250, "sponsor_name" => "Acme" }
      )
    end

    it "builds frame_url server-side from the asset token, path-segment encoded" do
      Wavebird.configure { |c| c.api_base_url = "https://api.wavebird.ai" }

      payload = described_class.call(decision)

      render = payload[:placement][:render]
      expect(render[:frame_url]).to eq("https://api.wavebird.ai/v1/render/at%20secret%2Ftoken")
      expect(payload).to include(fill: true)
      expect(render).to include(width: 300, height: 250, sponsor_name: "Acme", strategy: "hosted_frame")
    end

    it "never leaks the bare asset_token to the browser payload" do
      payload = described_class.call(decision)

      expect(payload).not_to have_key(:asset_token)
      expect(payload.to_json).not_to include("at secret/token") # only URL-encoded, inside frame_url
    end

    it "respects a custom api_base_url" do
      Wavebird.configure { |c| c.api_base_url = "https://sandbox.wavebird.ai" }

      expect(described_class.call(decision).dig(:placement, :render, :frame_url))
        .to start_with("https://sandbox.wavebird.ai/v1/render/")
    end
  end

  describe "degenerate fills" do
    it "handles a fill decision with no creative block" do
      decision = Wavebird::Types::Decision.from_api(
        "slot_id" => "slot_1", "status" => "ready", "fill" => true, "asset_token" => "at_x"
      )

      payload = described_class.call(decision)

      # Falls back to the render script's own default box (300x250) when the
      # decision carries no creative, exactly as its renderFrom would have.
      expect(payload[:placement][:render]).to include(
        frame_url: "https://api.wavebird.ai/v1/render/at_x", width: 300, height: 250
      )
    end

    it "reports a fill decision with no asset_token as a no-fill" do
      decision = Wavebird::Types::Decision.from_api("slot_id" => "slot_1", "status" => "ready", "fill" => true)

      expect(described_class.call(decision)).to eq(fill: false)
    end
  end

  describe ".slot_dom_id" do
    it "builds the slot's DOM id from the position" do
      expect(described_class.slot_dom_id("below")).to eq("wavebird-slot-below")
    end

    it "is the id the view helper renders, so broadcasts can target it" do
      view = ActionView::Base.with_empty_template_cache
                             .new(ActionView::LookupContext.new([]), {}, nil)
                             .tap { |v| v.extend(Wavebird::SlotHelper) }

      expect(view.wavebird_slot(endpoint: "/e", position: "sidebar"))
        .to include(%(id="#{described_class.slot_dom_id('sidebar')}"))
    end
  end

  describe ".stream_name" do
    it "scopes the stream to the session, not just the position" do
      expect(described_class.stream_name("below", "sess_1")).to eq("wavebird_slot_below_sess_1")
    end

    it "gives two visitors at the same position different streams" do
      expect(described_class.stream_name("below", "sess_a"))
        .not_to eq(described_class.stream_name("below", "sess_b"))
    end

    # Callers are expected to check first — the view helper degrades to a blocking
    # slot and the endpoint falls back to blocking (decision #016). This is the
    # invariant behind both: there is no such thing as an unscoped stream, because
    # one would be shared by every visitor at that position.
    it "refuses to build an unscoped stream" do
      expect { described_class.stream_name("below", nil) }
        .to raise_error(ArgumentError, /requires a session_id/)
    end

    it "treats a blank session id as no session id" do
      expect { described_class.stream_name("below", "   ") }.to raise_error(ArgumentError)
    end
  end

  describe "on no-fill" do
    it "returns { fill: false } for a no-fill placement response" do
      response = Wavebird::Types::PlacementResponse.from_api(
        "status" => "no_fill", "placement" => nil, "decision" => nil
      )

      expect(described_class.call(response)).to eq(fill: false)
    end

    it "returns { fill: false } for a no-fill decision" do
      decision = Wavebird::Types::Decision.from_api("slot_id" => "slot_1", "status" => "ready", "fill" => false)

      expect(described_class.call(decision)).to eq(fill: false)
    end
  end
end
