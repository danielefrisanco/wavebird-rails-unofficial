# frozen_string_literal: true

RSpec.describe Wavebird::SponsorSlotsController, type: :request do
  include_context "with the wavebird engine mounted"

  let(:secret_key) { "sk_test_never_in_response" }
  let(:placements_url) { "https://api.wavebird.ai/v1/placements" }
  # A filled placement carrying browser-safe render fields plus sensitive proof
  # material (asset_token) that must NOT reach the browser except via frame_url.
  let(:fill_response) do
    {
      "slot_id" => "slot_1", "status" => "ready",
      "placement" => {
        "asset_token" => "at_secret_proof", "format" => "banner",
        "render" => {
          "strategy" => "hosted_frame",
          "frame_url" => "https://api.wavebird.ai/v1/render/at_secret_proof",
          "script_url" => "https://api.wavebird.ai/v1/render.js",
          "width" => 728, "height" => 90,
          "label_text" => "Sponsored", "sponsor_name" => "Acme"
        }
      },
      "decision" => { "fill" => true, "asset_token" => "at_secret_proof" }
    }
  end
  let(:no_fill_response) { { "slot_id" => "slot_1", "status" => "no_fill", "placement" => nil, "decision" => nil } }

  # The controller reads the global configuration through Wavebird.client.
  before do
    Wavebird.configure do |c|
      c.secret_key = secret_key
      c.client_id = "wbproj_spec"
    end
  end

  after { Wavebird.reset_configuration! }

  def json
    JSON.parse(last_response.body)
  end

  # create_placement calls POST /v1/placements?wait_ms=… — a bare stub URL does
  # not match a query-bearing request in WebMock, so match any query explicitly.
  def stub_placements
    stub_request(:post, placements_url).with(query: hash_including({}))
  end

  describe "POST /wavebird/sponsor_slot on fill" do
    before do
      stub_placements.to_return(
        status: 200, body: JSON.generate(fill_response), headers: { "Content-Type" => "application/json" }
      )
      post_json("/wavebird/sponsor_slot", session_id: "sess_1")
    end

    it "responds 200" do
      expect(last_response.status).to eq(200)
    end

    it "returns the browser-safe render fields" do
      expect(json).to include(
        "fill" => true,
        "frame_url" => "https://api.wavebird.ai/v1/render/at_secret_proof",
        "script_url" => "https://api.wavebird.ai/v1/render.js",
        "width" => 728, "height" => 90, "label_text" => "Sponsored", "sponsor_name" => "Acme"
      )
    end

    it "never includes the secret key in the response body" do
      expect(last_response.body).not_to include(secret_key)
      expect(last_response.body).not_to include("sk_test")
    end

    it "does not expose the bare asset_token as its own field" do
      # The token only crosses to the browser embedded in frame_url (the hosted
      # renderer authenticates the frame with it); it is never a standalone field.
      expect(json).not_to have_key("asset_token")
    end

    it "sends the secret key upstream as a server-side bearer token" do
      expect(a_request(:post, placements_url)
        .with(query: hash_including({}), headers: { "Authorization" => "Bearer #{secret_key}" }))
        .to have_been_made
    end
  end

  describe "POST /wavebird/sponsor_slot on a fill without a render block" do
    # A filled decision whose placement carries no hosted-frame render object —
    # the payload is just { fill: true }, every render field compacted away.
    let(:renderless_fill) do
      {
        "slot_id" => "slot_1", "status" => "ready",
        "placement" => { "asset_token" => "at_secret_proof", "format" => "banner" },
        "decision" => { "fill" => true }
      }
    end

    before do
      stub_placements.to_return(status: 200, body: JSON.generate(renderless_fill))
      post_json("/wavebird/sponsor_slot", session_id: "sess_1")
    end

    it "returns fill: true with no render fields" do
      expect(json).to eq("fill" => true)
    end
  end

  describe "POST /wavebird/sponsor_slot on no-fill" do
    before do
      stub_placements.to_return(status: 200, body: JSON.generate(no_fill_response))
      post_json("/wavebird/sponsor_slot", session_id: "sess_1")
    end

    it "responds 200 with a hide-slot payload" do
      expect(last_response.status).to eq(200)
      expect(json).to eq("fill" => false)
    end
  end

  describe "POST /wavebird/sponsor_slot when wavebird errors" do
    before do
      stub_placements.to_return(status: 500, body: JSON.generate("error" => "boom"))
      post_json("/wavebird/sponsor_slot", session_id: "sess_1")
    end

    it "still responds 200 with a hide-slot payload (host chat flow unaffected)" do
      expect(last_response.status).to eq(200)
      expect(json).to eq("fill" => false)
    end

    it "does not leak the secret key even on the error path" do
      expect(last_response.body).not_to include(secret_key)
    end
  end

  describe "request parameters" do
    it "defaults job_type to chat and forwards whitelisted slot context" do
      stub = stub_placements
             .with(body: hash_including("job_type" => "chat", "session_id" => "sess_1",
                                        "slot_hint" => { "position" => "below" }))
             .to_return(status: 200, body: JSON.generate(no_fill_response))

      post_json("/wavebird/sponsor_slot", session_id: "sess_1", slot_hint: { position: "below" })

      expect(stub).to have_been_requested
    end

    it "accepts an explicit job_type" do
      stub = stub_placements
             .with(body: hash_including("job_type" => "image"))
             .to_return(status: 200, body: JSON.generate(no_fill_response))

      post_json("/wavebird/sponsor_slot", job_type: "image")

      expect(stub).to have_been_requested
    end

    it "does not forward the user's raw prompt even if one is posted" do
      stub_placements.to_return(status: 200, body: JSON.generate(no_fill_response))

      post_json("/wavebird/sponsor_slot", session_id: "sess_1", prompt: "my credit card is 4111 1111 1111 1111")

      expect(a_request(:post, placements_url)
        .with(query: hash_including({})) { |req| !req.body.include?("4111") }).to have_been_made
    end
  end
end
