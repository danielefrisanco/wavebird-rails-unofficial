# frozen_string_literal: true

# The controller lazy-loads this on the async path; require it up front so the
# async-mode examples can reference the constant (ActiveJob is loaded by the
# harness — see spec/support/rails_app.rb).
require "wavebird/decision_poll_job"

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

  # create_job POSTs to /v1/jobs (async mode); match any query like the
  # placements stub above.
  def stub_jobs
    stub_request(:post, "https://api.wavebird.ai/v1/jobs").with(query: hash_including({}))
  end

  def accepted_job_body
    JSON.generate("job_id" => "job_1", "slot_ids" => ["slot_1"], "status" => "accepted")
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

    # The hosted renderer resolves the response via placementFrom({decision:
    # response}) -> response.placement -> .render, so the fields must be nested
    # exactly this way or it paints nothing (decision #017).
    it "returns the browser-safe render fields under placement.render" do
      expect(json).to include("fill" => true)
      expect(json.dig("placement", "render")).to include(
        "strategy" => "hosted_frame",
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
    # A filled decision whose placement carries no hosted-frame render object.
    # There is nothing the renderer can mount — its startTurn discards a
    # placement with no render and clears the slot — so the endpoint reports a
    # no-fill rather than a fill the browser cannot act on.
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

    it "hides the slot instead of claiming an unrenderable fill" do
      expect(json).to eq("fill" => false)
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

  # The browser is not a trusted source for anything that steers the auction or
  # asserts what wavebird may do with the request. A compromised or scripted page
  # must not be able to undo the publisher's server-side configuration.
  describe "POST /wavebird/sponsor_slot trust boundary", :aggregate_failures do
    before { stub_placements.to_return(status: 200, body: JSON.generate(no_fill_response)) }

    it "ignores browser-supplied overrides and keeps the configured ones" do
      Wavebird.configure { |c| c.default_overrides = { blocked_categories: ["gambling"] } }

      post_json("/wavebird/sponsor_slot", session_id: "sess_1",
                                          overrides: { blocked_categories: [], bidfloor: 0 })

      expect(a_request(:post, placements_url).with(query: hash_including({}),
                                                   body: hash_including(
                                                     "overrides" => { "blocked_categories" => ["gambling"] }
                                                   ))).to have_been_made
    end

    it "ignores browser-supplied consent" do
      post_json("/wavebird/sponsor_slot", session_id: "sess_1",
                                          consent: { semantic_targeting: true })

      expect(a_request(:post, placements_url)
        .with(query: hash_including({}),
              body: hash_including("consent" => anything))).not_to have_been_made
    end

    it "sends the consent the host configured server-side" do
      Wavebird.configure { |c| c.default_consent = { semantic_targeting: false } }

      post_json("/wavebird/sponsor_slot", session_id: "sess_1")

      expect(a_request(:post, placements_url)
        .with(query: hash_including({}),
              body: hash_including("consent" => { "semantic_targeting" => false }))).to have_been_made
    end
  end

  describe "POST /wavebird/sponsor_slot in async mode" do
    context "when Turbo Streams is available and a job is created" do
      before do
        stub_const("Turbo::StreamsChannel", Class.new)
        allow(Wavebird::DecisionPollJob).to receive(:perform_later)
        stub_jobs.to_return(status: 200, body: accepted_job_body)
      end

      it "enqueues the poll job and responds { pending: true } without waiting" do
        post_json("/wavebird/sponsor_slot", session_id: "sess_1", mode: "async", position: "below")

        expect(json).to eq("pending" => true)
        expect(Wavebird::DecisionPollJob)
          .to have_received(:perform_later).with("slot_1", "wavebird_slot_below_sess_1", "below")
      end

      # The stream is derived server-side from position + session id. Taking it
      # from params would let a client choose whose page its payload lands on.
      it "ignores a stream_name supplied by the client" do
        post_json("/wavebird/sponsor_slot", session_id: "sess_1", mode: "async", position: "below",
                                            stream_name: "wavebird_slot_below_sess_victim")

        expect(Wavebird::DecisionPollJob)
          .to have_received(:perform_later).with("slot_1", "wavebird_slot_below_sess_1", "below")
      end

      it "scopes two visitors at the same position to different streams" do
        post_json("/wavebird/sponsor_slot", session_id: "sess_a", mode: "async", position: "below")
        post_json("/wavebird/sponsor_slot", session_id: "sess_b", mode: "async", position: "below")

        expect(Wavebird::DecisionPollJob)
          .to have_received(:perform_later).with("slot_1", "wavebird_slot_below_sess_a", "below")
        expect(Wavebird::DecisionPollJob)
          .to have_received(:perform_later).with("slot_1", "wavebird_slot_below_sess_b", "below")
      end

      it "does not call the blocking placements endpoint" do
        post_json("/wavebird/sponsor_slot", session_id: "sess_1", mode: "async")

        expect(a_request(:post, placements_url)).not_to have_been_made
      end

      # Async used to strip consent entirely, so the same host code sent a GDPR
      # flag in blocking mode and silently dropped it here. The canonical jobs
      # route carries it as overrides.gdpr_applies (upstream createV1JobRequest).
      it "forwards the configured consent flag the canonical jobs route can carry" do
        Wavebird.configure { |c| c.default_consent = { gdpr_applies: true } }

        post_json("/wavebird/sponsor_slot", session_id: "sess_1", mode: "async")

        expect(a_request(:post, "https://api.wavebird.ai/v1/jobs")
          .with(query: hash_including({}),
                body: hash_including("overrides" => { "gdpr_applies" => true }))).to have_been_made
      end
    end

    # A 429 is the API asking us to back off. Upstream's createJob answers it
    # with a rate-limit value rather than an error, and retrying the same work
    # through the blocking path would just spend the next 429.
    context "when the jobs endpoint rate limits the request" do
      before do
        stub_const("Turbo::StreamsChannel", Class.new)
        allow(Wavebird::DecisionPollJob).to receive(:perform_later)
        stub_jobs.to_return(status: 429, headers: { "Retry-After" => "30" },
                            body: JSON.generate("error" => "rate_limited"))
      end

      it "hides the slot instead of retrying through the blocking path" do
        post_json("/wavebird/sponsor_slot", session_id: "sess_1", mode: "async", position: "below")

        expect(json).to eq("fill" => false)
        expect(a_request(:post, placements_url)).not_to have_been_made
        expect(Wavebird::DecisionPollJob).not_to have_received(:perform_later)
      end
    end

    # Without a session id the stream could only be named for the position, which
    # is exactly the shared-channel bug. Blocking delivery needs no stream at all,
    # so it degrades there rather than broadcasting to everyone.
    context "when async is requested without a session id" do
      before do
        stub_const("Turbo::StreamsChannel", Class.new)
        allow(Wavebird::DecisionPollJob).to receive(:perform_later)
        stub_placements.to_return(status: 200, body: JSON.generate(no_fill_response))
      end

      it "falls back to the blocking path instead of using an unscoped stream" do
        post_json("/wavebird/sponsor_slot", mode: "async", position: "below")

        expect(json).to eq("fill" => false)
        expect(Wavebird::DecisionPollJob).not_to have_received(:perform_later)
      end

      it "warns that the session id is what scopes the stream" do
        logger = instance_double(Logger, warn: nil)
        Wavebird.configure { |c| c.logger = logger }

        post_json("/wavebird/sponsor_slot", mode: "async", position: "below")

        expect(logger).to have_received(:warn).with(/without a session_id/)
      end
    end

    context "when Turbo Streams is not available" do
      before do
        hide_const("Turbo::StreamsChannel") if defined?(Turbo::StreamsChannel)
        stub_placements.to_return(status: 200, body: JSON.generate(no_fill_response))
      end

      it "falls back to the blocking path so the slot still resolves" do
        post_json("/wavebird/sponsor_slot", session_id: "sess_1", mode: "async")

        expect(last_response.status).to eq(200)
        expect(json).to eq("fill" => false)
        expect(a_request(:post, placements_url).with(query: hash_including({}))).to have_been_made
      end

      it "warns via the configured logger that async is unavailable" do
        logger = instance_spy(Logger)
        Wavebird.configure { |c| c.logger = logger }

        post_json("/wavebird/sponsor_slot", session_id: "sess_1", mode: "async")

        expect(logger).to have_received(:warn).with(/async mode requested but Turbo Streams/)
      end
    end

    context "when the job could not be created" do
      before do
        stub_const("Turbo::StreamsChannel", Class.new)
        stub_jobs.to_return(status: 500, body: JSON.generate("error" => "boom"))
        stub_placements.to_return(status: 200, body: JSON.generate(no_fill_response))
      end

      it "falls back to the blocking path (create_job failed fail-silently)" do
        post_json("/wavebird/sponsor_slot", session_id: "sess_1", mode: "async")

        expect(json).to eq("fill" => false)
        expect(a_request(:post, placements_url).with(query: hash_including({}))).to have_been_made
      end
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
