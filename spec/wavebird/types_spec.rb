# frozen_string_literal: true

RSpec.describe Wavebird::Types do
  # Mirrors the /v1/placements sandbox example (build prompt §3.1) plus the
  # WavebirdPlacement/CslWrapperDecisionFillV1 contract fields.
  let(:fill_placement_body) do
    {
      "slot_id" => "slot_123",
      "status" => "ready",
      "placement" => {
        "image_url" => "https://cdn.wavebird.ai/creative.png",
        "video_url" => nil,
        "click_url" => "https://click.wavebird.ai/c/abc",
        "sponsor_name" => "Acme",
        "width" => 728,
        "height" => 90,
        "format" => "banner",
        "asset_token" => "at_secret_proof",
        "ad_label_text" => "Sponsored",
        "render" => {
          "strategy" => "hosted_frame",
          "frame_url" => "https://api.wavebird.ai/v1/render/at_secret_proof",
          "script_url" => "https://api.wavebird.ai/v1/render.js",
          "media_type" => "image",
          "width" => 728,
          "height" => 90,
          "aspect_ratio" => "728:90",
          "label_text" => "Sponsored",
          "sponsor_name" => "Acme",
          "click_url" => "https://click.wavebird.ai/c/abc",
          "native_template_id" => nil
        }
      },
      "decision" => {
        "slot_id" => "slot_123",
        "status" => "ready",
        "fill" => true,
        "reason" => nil,
        "no_fill_reason" => nil,
        "creative" => {
          "url" => "https://cdn.wavebird.ai/creative.png",
          "type" => "banner",
          "duration_ms" => 0,
          "width" => 728,
          "height" => 90,
          "mime_type" => "image/png",
          "click_through_url" => "https://click.wavebird.ai/c/abc",
          "sponsor_name" => "Acme",
          "native_assets" => nil
        },
        "asset_token" => "at_secret_proof",
        "constraints" => { "max_render_ms" => 5000 },
        "cs_declaration" => "csd_1",
        "revenue_estimate" => { "gross_cpm" => 1.2, "currency" => "EUR" }
      }
    }
  end

  let(:no_fill_body) do
    {
      "slot_id" => "slot_123",
      "status" => "ready",
      "placement" => nil,
      "decision" => {
        "slot_id" => "slot_123",
        "status" => "ready",
        "fill" => false,
        "reason" => "no_bid",
        "no_fill_reason" => "no_eligible_campaign",
        "creative" => nil,
        "asset_token" => nil,
        "constraints" => nil,
        "cs_declaration" => "csd_1",
        "revenue_estimate" => nil
      }
    }
  end

  describe Wavebird::Types::PlacementResponse do
    it "round-trips the fill example field-for-field" do
      response = described_class.from_api(fill_placement_body)

      expect(response.slot_id).to eq("slot_123")
      expect(response.status).to eq("ready")
      expect(response.placement.format).to eq("banner")
      expect(response.placement.render.frame_url).to eq("https://api.wavebird.ai/v1/render/at_secret_proof")
      expect(response.decision.creative.mime_type).to eq("image/png")
    end

    it "is a fill when placement present and decision.fill true" do
      response = described_class.from_api(fill_placement_body)

      expect(response.fill?).to be(true)
      expect(response.no_fill?).to be(false)
    end

    it "treats null placement as first-class no-fill, not an error" do
      response = described_class.from_api(no_fill_body)

      expect(response.placement).to be_nil
      expect(response.fill?).to be(false)
      expect(response.no_fill?).to be(true)
      expect(response.decision.no_fill?).to be(true)
    end

    it "does not report fill when the decision is missing entirely" do
      response = described_class.from_api("slot_id" => "slot_123", "status" => "ready",
                                          "placement" => fill_placement_body["placement"])

      expect(response.fill?).to be(false)
    end

    it "accepts symbol keys" do
      response = described_class.from_api(slot_id: "slot_9", status: "ready", placement: nil, decision: nil)

      expect(response.slot_id).to eq("slot_9")
    end

    it "keeps unknown fields available via raw" do
      response = described_class.from_api(fill_placement_body.merge("future_field" => 42))

      expect(response.raw["future_field"]).to eq(42)
    end
  end

  describe Wavebird::Types::Decision do
    it "models the pending variant" do
      decision = described_class.from_api("slot_id" => "slot_1", "status" => "pending", "fill" => nil)

      expect(decision.pending?).to be(true)
      expect(decision.ready?).to be(false)
      expect(decision.fill?).to be(false)
      expect(decision.no_fill?).to be(false)
    end

    it "models the ready no-fill variant" do
      decision = described_class.from_api(no_fill_body["decision"])

      expect(decision.ready?).to be(true)
      expect(decision.no_fill?).to be(true)
      expect(decision.reason).to eq("no_bid")
      expect(decision.no_fill_reason).to eq("no_eligible_campaign")
    end

    it "models the ready fill variant with nested creative" do
      decision = described_class.from_api(fill_placement_body["decision"])

      expect(decision.fill?).to be(true)
      expect(decision.creative.width).to eq(728)
      expect(decision.constraints).to eq("max_render_ms" => 5000)
      expect(decision.revenue_estimate["gross_cpm"]).to eq(1.2)
    end

    it "returns nil for nil input" do
      expect(described_class.from_api(nil)).to be_nil
    end
  end

  describe Wavebird::Types::Placement do
    it "tolerates a placement without a render object" do
      placement = described_class.from_api("format" => "banner", "asset_token" => "at_1", "render" => nil)

      expect(placement.render).to be_nil
      expect(placement.format).to eq("banner")
    end
  end

  describe Wavebird::Types::NativeAssets do
    it "carries the native creative contract fields" do
      assets = described_class.from_api(
        "title" => "Try Acme", "image_url" => "https://cdn/img.png",
        "description" => "desc", "cta_text" => "Go", "icon_url" => nil
      )

      expect(assets.title).to eq("Try Acme")
      expect(assets.image_url).to eq("https://cdn/img.png")
      expect(assets.cta_text).to eq("Go")
    end

    it "is reachable from a native creative" do
      creative = Wavebird::Types::Creative.from_api(
        "url" => "u", "type" => "native", "native_assets" => { "title" => "T", "image_url" => "i" }
      )

      expect(creative.native_assets.title).to eq("T")
    end
  end

  describe Wavebird::Types::AcceptedJob do
    it "carries job_id, slot_ids and status" do
      job = described_class.from_api("job_id" => "job_1", "slot_ids" => %w[slot_1 slot_2], "status" => "accepted")

      expect(job.job_id).to eq("job_1")
      expect(job.slot_ids).to eq(%w[slot_1 slot_2])
      expect(job.status).to eq("accepted")
    end
  end

  describe Wavebird::Types::BeaconResult do
    it "models an accepted beacon" do
      result = described_class.from_api("ok" => true, "accepted" => true, "duplicate" => false,
                                        "reason_code" => "OK")

      expect(result.accepted?).to be(true)
      expect(result.duplicate?).to be(false)
    end

    it "treats idempotent duplicates as flagged successes" do
      result = described_class.from_api("ok" => true, "accepted" => true, "duplicate" => true, "reason_code" => "OK")

      expect(result.accepted?).to be(true)
      expect(result.duplicate?).to be(true)
    end

    it "keeps diagnostic fields in raw (endpoint may grow fields)" do
      result = described_class.from_api(
        "ok" => true, "accepted" => true, "duplicate" => false, "reason_code" => "OK",
        "proof_source" => "hosted_renderer", "billable" => false, "geometry_reason" => nil
      )

      expect(result.raw["proof_source"]).to eq("hosted_renderer")
      expect(result.raw["billable"]).to be(false)
    end
  end

  describe Wavebird::Types::ConsentState do
    it "carries decision, source and purposes" do
      state = described_class.from_api("decision" => "custom", "source" => "publisher_custom",
                                       "purposes" => { "semantic_targeting" => false })

      expect(state.decision).to eq("custom")
      expect(state.source).to eq("publisher_custom")
      expect(state.purposes).to eq("semantic_targeting" => false)
    end
  end

  describe Wavebird::Types::ProjectConfig do
    it "exposes the server-owned config via #[]" do
      config = described_class.from_api("client_id" => "wbproj_1", "formats" => %w[banner])

      expect(config["client_id"]).to eq("wbproj_1")
      expect(config[:formats]).to eq(%w[banner])
    end
  end

  describe "asset_token redaction" do
    it "redacts asset_token in Placement#inspect and #to_s" do
      placement = Wavebird::Types::Placement.from_api(fill_placement_body["placement"])

      expect(placement.inspect).not_to include("at_secret_proof")
      expect(placement.inspect).to include("asset_token=\"[REDACTED]\"")
      expect(placement.to_s).not_to include("at_secret_proof")
    end

    it "redacts asset_token in Decision#inspect" do
      decision = Wavebird::Types::Decision.from_api(fill_placement_body["decision"])

      expect(decision.inspect).not_to include("at_secret_proof")
    end

    it "never dumps raw (which may contain tokens) from any object" do
      response = Wavebird::Types::PlacementResponse.from_api(fill_placement_body)

      expect(response.inspect).not_to include("at_secret_proof")
    end

    it "shows nil asset_token as nil, not as redacted" do
      decision = Wavebird::Types::Decision.from_api(no_fill_body["decision"])

      expect(decision.inspect).to include("asset_token=nil")
    end
  end
end
