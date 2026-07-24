# frozen_string_literal: true

RSpec.describe Wavebird::DecisionNormalizer do
  # Canonical GET /v1/decisions/{slot_id} ready-fill body, per upstream
  # normalizeV1Decision (banner/clip shape uses delivery_url + dimensions).
  let(:fill_body) do
    {
      "slot_id" => "slot_1",
      "status" => "ready",
      "decision" => {
        "fill" => true,
        "format" => "banner",
        "asset_token" => "at_secret_proof",
        "cs_declaration" => "csd_1",
        "constraints" => { "max_render_ms" => 5000 },
        "dimensions" => { "width" => 728, "height" => 90 },
        "duration_ms" => 0,
        "delivery_url" => "https://cdn.wavebird.ai/creative.png",
        "click_url" => "https://click.wavebird.ai/c/abc",
        "sponsor_name" => "Acme",
        "mime_type" => "image/png",
        "assets" => nil,
        "revenue_estimate" => { "gross_cpm" => 1.2 },
        "metadata" => { "campaign" => "c_1" }
      }
    }
  end

  let(:no_fill_body) do
    {
      "slot_id" => "slot_1",
      "status" => "ready",
      "decision" => {
        "fill" => false,
        "reason" => "no_bid",
        "no_fill_reason" => "no_eligible_campaign",
        "cs_declaration" => "csd_1"
      }
    }
  end

  def normalize(body)
    described_class.call(body)
  end

  def with_decision(body, changes)
    body.merge("decision" => body["decision"].merge(changes))
  end

  describe "pending decisions" do
    it "returns a pending decision for status pending with a null decision" do
      decision = normalize("slot_id" => "slot_1", "status" => "pending", "decision" => nil)

      expect(decision.pending?).to be(true)
      expect(decision.fill).to be_nil
    end

    it "keeps envelope metadata on pending decisions" do
      decision = normalize("slot_id" => "slot_1", "status" => "pending", "decision" => nil,
                           "metadata" => { "queue" => "fast" })

      expect(decision.metadata).to eq("queue" => "fast")
    end

    it "rejects status pending with a present decision" do
      body = no_fill_body.merge("status" => "pending")

      expect { normalize(body) }.to raise_error(Wavebird::InvalidResponseError)
    end
  end

  describe "envelope validation" do
    it "rejects a non-hash body" do
      expect { normalize([1]) }.to raise_error(Wavebird::InvalidResponseError)
    end

    it "rejects a missing slot_id" do
      expect { normalize(fill_body.merge("slot_id" => "  ")) }.to raise_error(Wavebird::InvalidResponseError)
    end

    it "rejects a ready status with a non-hash decision" do
      expect { normalize("slot_id" => "slot_1", "status" => "ready", "decision" => "yes") }
        .to raise_error(Wavebird::InvalidResponseError)
    end

    it "rejects a non-boolean fill" do
      expect { normalize(with_decision(fill_body, "fill" => "true")) }
        .to raise_error(Wavebird::InvalidResponseError)
    end

    it "accepts symbol keys" do
      decision = normalize(slot_id: "slot_1", status: "pending", decision: nil)

      expect(decision.slot_id).to eq("slot_1")
    end
  end

  describe "ready no-fill decisions" do
    it "normalizes the no-fill variant" do
      decision = normalize(no_fill_body)

      expect(decision.no_fill?).to be(true)
      expect(decision.reason).to eq("no_bid")
      expect(decision.no_fill_reason).to eq("no_eligible_campaign")
      expect(decision.cs_declaration).to eq("csd_1")
    end

    it "keeps decision metadata when present" do
      decision = normalize(with_decision(no_fill_body, "metadata" => { "audit" => true }))

      expect(decision.metadata).to eq("audit" => true)
    end

    %w[reason no_fill_reason cs_declaration].each do |field|
      it "requires #{field}" do
        expect { normalize(with_decision(no_fill_body, field => nil)) }
          .to raise_error(Wavebird::InvalidResponseError)
      end
    end
  end

  describe "ready fill decisions" do
    it "builds the creative from the canonical fields" do
      decision = normalize(fill_body)

      expect(decision.fill?).to be(true)
      expect(decision.asset_token).to eq("at_secret_proof")
      expect(decision.creative.url).to eq("https://cdn.wavebird.ai/creative.png")
      expect(decision.creative.type).to eq("banner")
      expect(decision.creative.click_through_url).to eq("https://click.wavebird.ai/c/abc")
    end

    it "carries dimensions, duration, sponsor, mime type, revenue and metadata" do
      decision = normalize(fill_body)

      expect(decision.creative.width).to eq(728)
      expect(decision.creative.height).to eq(90)
      expect(decision.creative.duration_ms).to eq(0)
      expect(decision.creative.sponsor_name).to eq("Acme")
      expect(decision.revenue_estimate).to eq("gross_cpm" => 1.2)
    end

    it "requires a known format" do
      expect { normalize(with_decision(fill_body, "format" => "popup")) }
        .to raise_error(Wavebird::InvalidResponseError)
    end

    %w[asset_token cs_declaration].each do |field|
      it "requires #{field}" do
        expect { normalize(with_decision(fill_body, field => nil)) }
          .to raise_error(Wavebird::InvalidResponseError)
      end
    end

    it "requires constraints to be an object" do
      expect { normalize(with_decision(fill_body, "constraints" => nil)) }
        .to raise_error(Wavebird::InvalidResponseError)
    end

    it "omits optional creative fields when blank" do
      decision = normalize(with_decision(fill_body, "click_url" => nil, "sponsor_name" => " ", "mime_type" => 3))

      expect(decision.creative.click_through_url).to be_nil
      expect(decision.creative.sponsor_name).to be_nil
      expect(decision.creative.mime_type).to be_nil
    end

    it "omits a malformed revenue_estimate (kept server-tolerant)" do
      decision = normalize(with_decision(fill_body, "revenue_estimate" => "high"))

      expect(decision.revenue_estimate).to be_nil
    end
  end

  describe "dimensions and duration defaults" do
    it "requires the dimensions key to be present" do
      body = fill_body
      body["decision"].delete("dimensions")

      expect { normalize(body) }.to raise_error(Wavebird::InvalidResponseError)
    end

    it "accepts a symbol dimensions key" do
      body = fill_body
      body["decision"].delete("dimensions")
      body["decision"][:dimensions] = { "width" => 10, "height" => 20 }

      expect(normalize(body).creative.width).to eq(10)
    end

    it "applies the default box for null dimensions" do
      decision = normalize(with_decision(fill_body, "dimensions" => nil))

      expect(decision.creative.width).to eq(300)
      expect(decision.creative.height).to eq(250)
    end

    it "rejects a non-object dimensions value" do
      expect { normalize(with_decision(fill_body, "dimensions" => "728x90")) }
        .to raise_error(Wavebird::InvalidResponseError)
    end

    it "falls back per-axis for non-finite dimension values" do
      decision = normalize(with_decision(fill_body, "dimensions" => { "width" => "728", "height" => Float::NAN }))

      expect(decision.creative.width).to eq(300)
      expect(decision.creative.height).to eq(250)
    end

    it "applies the default duration when duration_ms is missing" do
      decision = normalize(with_decision(fill_body, "duration_ms" => nil))

      expect(decision.creative.duration_ms).to eq(3000)
    end
  end

  describe "native fills" do
    let(:native_body) do
      with_decision(fill_body,
                    "format" => "native", "delivery_url" => nil,
                    "assets" => { "title" => "Try Acme", "image_url" => "https://cdn/img.png",
                                  "description" => "desc", "cta_text" => "Go", "icon_url" => " " })
    end

    it "uses the native image as the creative url and keeps non-blank asset fields" do
      decision = normalize(native_body)

      expect(decision.creative.url).to eq("https://cdn/img.png")
      expect(decision.creative.native_assets.title).to eq("Try Acme")
      expect(decision.creative.native_assets.cta_text).to eq("Go")
      expect(decision.creative.native_assets.icon_url).to be_nil
    end

    it "requires assets for native fills" do
      expect { normalize(with_decision(native_body, "assets" => nil)) }
        .to raise_error(Wavebird::InvalidResponseError)
    end

    it "requires title and image_url inside assets" do
      expect { normalize(with_decision(native_body, "assets" => { "title" => "T" })) }
        .to raise_error(Wavebird::InvalidResponseError)
    end

    it "requires delivery_url for non-native fills" do
      expect { normalize(with_decision(fill_body, "delivery_url" => nil)) }
        .to raise_error(Wavebird::InvalidResponseError)
    end
  end
end
