# frozen_string_literal: true

RSpec.describe Wavebird::Client, "decisions" do
  include_context "with a configured client"

  let(:slot_id) { "slot_123" }
  let(:decision_url) { "#{api_base}/v1/decisions/#{slot_id}" }

  let(:pending_body) { { "slot_id" => slot_id, "status" => "pending", "decision" => nil } }
  # Canonical banner fill shape: delivery_url + an explicitly present
  # dimensions key (see decision_normalizer_spec).
  let(:fill_body) do
    { "slot_id" => slot_id, "status" => "ready",
      "decision" => { "fill" => true, "format" => "banner",
                      "asset_token" => "at_secret_proof", "cs_declaration" => "csd_1",
                      "constraints" => {}, "dimensions" => { "width" => 728, "height" => 90 },
                      "delivery_url" => "https://cdn.wavebird.ai/creative.png" } }
  end
  let(:no_fill_body) do
    { "slot_id" => slot_id, "status" => "ready",
      "decision" => { "fill" => false, "reason" => "no_bid", "no_fill_reason" => "no_bid",
                      "ad_label_text" => "Sponsored", "cs_declaration" => "csd_1" } }
  end

  # Matches every rung of the ladder — long polls carry wait_ms, short polls
  # send no query at all.
  def stub_any_poll
    stub_request(:get, decision_url).with(query: hash_including({}))
  end

  # The ladder sleeps between short polls; specs assert on the durations rather
  # than paying them.
  before { allow(client).to receive(:sleep) }

  describe "#decision" do
    it "long-polls with the configured wait_ms by default" do
      stub = stub_request(:get, decision_url)
             .with(query: { "wait_ms" => "1500" })
             .to_return(status: 200, body: JSON.generate(fill_body))

      expect(client.decision(slot_id)).to be_fill
      expect(stub).to have_been_requested
    end

    it "omits wait_ms entirely for a short poll" do
      stub = stub_request(:get, decision_url).to_return(status: 200, body: JSON.generate(pending_body))

      expect(client.decision(slot_id, wait_ms: 0)).to be_pending
      expect(stub).to have_been_requested
    end

    it "clamps wait_ms to the upstream 0..5000 range" do
      stub = stub_request(:get, decision_url)
             .with(query: { "wait_ms" => "5000" })
             .to_return(status: 200, body: JSON.generate(fill_body))

      client.decision(slot_id, wait_ms: 90_000)

      expect(stub).to have_been_requested
    end

    it "escapes the slot id in the path" do
      stub = stub_request(:get, "#{api_base}/v1/decisions/slot%2Fweird%20id")
             .with(query: { "wait_ms" => "1500" })
             .to_return(status: 200, body: JSON.generate(fill_body))

      client.decision("slot/weird id")

      expect(stub).to have_been_requested
    end

    it "rejects a non-numeric wait_ms" do
      expect { client.decision(slot_id, wait_ms: "soon") }.to raise_error(ArgumentError, /wait_ms must be a number/)
    end
  end

  describe "#await_decision" do
    it "returns the first ready decision without further polling" do
      stub = stub_request(:get, decision_url)
             .with(query: { "wait_ms" => "1500" })
             .to_return(status: 200, body: JSON.generate(fill_body))

      expect(client.await_decision(slot_id)).to be_fill
      expect(stub).to have_been_requested.once
    end

    it "treats a ready no-fill as a final answer, not a reason to keep polling" do
      stub_request(:get, decision_url)
        .with(query: { "wait_ms" => "1500" })
        .to_return(status: 200, body: JSON.generate(no_fill_body))

      decision = client.await_decision(slot_id)

      expect(decision).to be_no_fill
      expect(decision).to be_ready
    end

    it "falls through both long polls to the short-poll ladder" do
      long_poll = stub_request(:get, decision_url)
                  .with(query: { "wait_ms" => "1500" })
                  .to_return(status: 200, body: JSON.generate(pending_body))
      short_poll = stub_request(:get, decision_url)
                   .with(query: {})
                   .to_return(status: 200, body: JSON.generate(fill_body))

      expect(client.await_decision(slot_id)).to be_fill
      expect(long_poll).to have_been_requested.times(described_class::LONG_POLL_ATTEMPTS)
      expect(short_poll).to have_been_requested.once
    end

    context "with short-poll backoff" do
      # Every wait the ladder takes before giving up, in milliseconds.
      let(:slept) { [] }

      before do
        stub_any_poll.to_return(status: 200, body: JSON.generate(pending_body))
        allow(client).to receive(:sleep) { |seconds| slept << (seconds * 1000) }
        begin
          client.await_decision(slot_id)
        rescue Wavebird::DecisionTimeoutError
          nil # the exhausted budget is the precondition, not the assertion
        end
      end

      # interval * 1.5**attempt, jittered by 0...JITTER_MS.
      it "grows the wait by BACKOFF_FACTOR on each attempt" do
        expect(slept.first).to be_within(described_class::JITTER_MS).of(config.short_poll_interval_ms)
        expect(slept[1]).to be_within(described_class::JITTER_MS).of(config.short_poll_interval_ms * 1.5)
      end

      it "grows monotonically until it reaches the cap" do
        growing = slept.take_while { |ms| ms < described_class::BACKOFF_CAP_MS }

        expect(growing.size).to be >= 3
        expect(growing).to eq(growing.sort)
      end

      # Past the cap jitter makes successive waits wobble around it.
      it "never waits longer than BACKOFF_CAP_MS plus jitter" do
        capped = slept.drop_while { |ms| ms < described_class::BACKOFF_CAP_MS }

        expect(slept.max).to be <= described_class::BACKOFF_CAP_MS + described_class::JITTER_MS
        expect(capped).to all(be_within(described_class::JITTER_MS).of(described_class::BACKOFF_CAP_MS))
      end
    end

    it "bounds attempts by the decision_timeout_ms budget" do
      config.decision_timeout_ms = 1_000 # / 250ms interval => 4 short-poll attempts
      stub = stub_any_poll.to_return(status: 200, body: JSON.generate(pending_body))

      expect { client.await_decision(slot_id) }.to raise_error(Wavebird::DecisionTimeoutError, /1000ms/)
      expect(stub).to have_been_requested.times(described_class::LONG_POLL_ATTEMPTS + 4)
    end

    it "reports failed polls through on_error and keeps polling (upstream behavior)" do
      observed = []
      config.on_error = ->(error) { observed << error }
      stub_request(:get, decision_url)
        .with(query: { "wait_ms" => "1500" })
        .to_return(status: 503, body: JSON.generate({ "error" => "upstream_unavailable" }))
      stub_request(:get, decision_url)
        .with(query: {})
        .to_return(status: 200, body: JSON.generate(fill_body))

      expect(client.await_decision(slot_id)).to be_fill
      expect(observed.size).to eq(described_class::LONG_POLL_ATTEMPTS)
      expect(observed).to all(be_a(Wavebird::APIError))
    end

    it "logs swallowed poll failures without the secret key" do
      logger = instance_spy(Logger)
      config.logger = logger
      stub_any_poll.to_return(status: 500, body: "")

      expect { client.await_decision(slot_id) }.to raise_error(Wavebird::DecisionTimeoutError)
      expect(logger).to have_received(:warn).with(/\[wavebird\] Wavebird::/).at_least(:once)
      expect(logger).not_to have_received(:warn).with(/sk_test/)
    end

    it "survives an on_error observer that itself raises" do
      config.on_error = ->(_error) { raise "observer blew up" }
      stub_request(:get, decision_url)
        .with(query: { "wait_ms" => "1500" })
        .to_return(status: 500, body: "")
      stub_request(:get, decision_url)
        .with(query: {})
        .to_return(status: 200, body: JSON.generate(fill_body))

      expect(client.await_decision(slot_id)).to be_fill
    end

    it "raises DecisionTimeoutError when the budget is exhausted" do
      stub_any_poll.to_return(status: 200, body: JSON.generate(pending_body))

      expect { client.await_decision(slot_id) }
        .to raise_error(Wavebird::DecisionTimeoutError, /slot_123/) { |e| expect(e.code).to eq("decision_timeout") }
    end
  end
end
