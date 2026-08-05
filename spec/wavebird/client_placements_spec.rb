# frozen_string_literal: true

RSpec.describe Wavebird::Client, "#create_placement" do
  include_context "with a configured client"

  # Mirrors the build prompt §3.1 sandbox response.
  let(:fill_response) do
    {
      "slot_id" => "slot_123",
      "status" => "ready",
      "placement" => {
        "format" => "banner", "width" => 728, "height" => 90, "sponsor_name" => "Acme",
        "click_url" => "https://click.wavebird.ai/c/abc", "asset_token" => "at_secret_proof",
        "ad_label_text" => "Sponsored",
        "render" => { "strategy" => "hosted_frame",
                      "frame_url" => "https://api.wavebird.ai/v1/render/at_secret_proof",
                      "script_url" => "https://api.wavebird.ai/v1/render.js" }
      },
      "decision" => { "slot_id" => "slot_123", "status" => "ready", "fill" => true,
                      "asset_token" => "at_secret_proof", "cs_declaration" => "csd_1" }
    }
  end

  let(:placements_url) { "#{api_base}/v1/placements" }

  it "posts the §3.1 body with the recommended wait_ms and returns a fill" do
    stub = stub_request(:post, placements_url)
           .with(query: { "wait_ms" => "1500" },
                 body: { client_id: "wbproj_spec", session_id: "sess_1", job_type: "chat", slots_requested: 1,
                         slot_hint: { position: "below", max_width: 728, max_height: 90 },
                         consent: { semantic_targeting: false } },
                 headers: { "Content-Type" => "application/json" })
           .to_return(status: 200, body: JSON.generate(fill_response))

    response = client.create_placement(job_type: "chat", session_id: "sess_1",
                                       slot_hint: { position: "below", max_width: 728, max_height: 90 },
                                       consent: { semantic_targeting: false })

    expect(stub).to have_been_requested
    expect(response.fill?).to be(true)
    expect(response.placement.render.frame_url).to eq("https://api.wavebird.ai/v1/render/at_secret_proof")
  end

  it "treats a null placement as first-class no-fill, not an error" do
    stub_request(:post, placements_url)
      .with(query: hash_including("wait_ms"))
      .to_return(status: 200, body: JSON.generate(
        "slot_id" => "slot_123", "status" => "ready", "placement" => nil,
        "decision" => { "slot_id" => "slot_123", "status" => "ready", "fill" => false, "reason" => "no_bid" }
      ))

    response = client.create_placement(job_type: "chat")

    expect(response.no_fill?).to be(true)
    expect(response.placement).to be_nil
  end

  # The canonical job body carries both (upstream createV1JobRequest), and the
  # placements route accepts them — verified against the sandbox on 2026-08-05,
  # where an unknown field in the same position is rejected with a 400.
  it "sends topic as prompt.topic and the locale hint, like create_job" do
    stub = stub_request(:post, placements_url)
           .with(query: hash_including("wait_ms"),
                 body: { client_id: "wbproj_spec", job_type: "chat", locale: "de-DE", slots_requested: 1,
                         prompt: { topic: "cloud hosting" } })
           .to_return(status: 200, body: JSON.generate(fill_response))

    client.create_placement(job_type: "chat", topic: "cloud hosting", locale: "de-DE")

    expect(stub).to have_been_requested
  end

  it "omits prompt and locale when the caller sends neither" do
    stub = stub_request(:post, placements_url)
           .with(query: hash_including("wait_ms"),
                 body: { client_id: "wbproj_spec", job_type: "chat", slots_requested: 1 })
           .to_return(status: 200, body: JSON.generate(fill_response))

    client.create_placement(job_type: "chat")

    expect(stub).to have_been_requested
  end

  it "clamps wait_ms to the shared 0..5000 range and stretches the HTTP timeout" do
    stub = stub_request(:post, placements_url).with(query: { "wait_ms" => "5000" })
                                              .to_return(status: 200, body: JSON.generate(fill_response))

    client.create_placement(job_type: "chat", wait_ms: 60_000)

    expect(stub).to have_been_requested
  end

  it "rejects a non-numeric wait_ms" do
    expect { client.create_placement(job_type: "chat", wait_ms: "fast") }
      .to raise_error(ArgumentError, /wait_ms/)
  end

  it "merges configured defaults: slot_hint, overrides and publisher" do
    config.default_slot_hint = { position: "below" }
    config.default_overrides = { allowed_formats: %w[banner], timing: "during" }
    config.default_publisher = { app_name: "SpecApp" }
    stub = stub_request(:post, placements_url)
           .with(query: hash_including("wait_ms"),
                 body: { client_id: "wbproj_spec", job_type: "chat", slots_requested: 1,
                         slot_hint: { position: "below" },
                         overrides: { allowed_formats: %w[banner], timing: "twin_peaks",
                                      publisher: { app_name: "SpecApp", app_domain: "spec.example" } } })
           .to_return(status: 200, body: JSON.generate(fill_response))

    client.create_placement(job_type: "chat", overrides: { timing: "twin_peaks" },
                            publisher: { app_domain: "spec.example" })

    expect(stub).to have_been_requested
  end

  it "raises ConfigurationError without a client_id" do
    config.client_id = nil

    expect { client.create_placement(job_type: "chat") }
      .to raise_error(Wavebird::ConfigurationError, /client_id/)
  end

  it "rejects an empty success body" do
    stub_request(:post, placements_url).with(query: hash_including("wait_ms")).to_return(status: 200, body: "")

    expect { client.create_placement(job_type: "chat") }.to raise_error(Wavebird::InvalidResponseError)
  end
end
