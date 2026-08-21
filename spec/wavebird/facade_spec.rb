# frozen_string_literal: true

RSpec.describe Wavebird::Facade do
  let(:config) do
    Wavebird::Configuration.new.tap do |c|
      c.secret_key = "sk_test_spec_placeholder"
      c.client_id = "wbproj_spec"
    end
  end
  # A raising low-level client stand-in; verify_partial_doubles keeps the stubs
  # honest against the real Client signature.
  let(:client) { instance_double(Wavebird::Client) }
  let(:facade) { described_class.new(config: config, client: client) }

  describe "#create_placement" do
    it "returns the client's response untouched on success" do
      response = Wavebird::Types::PlacementResponse.from_api(
        "status" => "ready",
        "placement" => { "asset_token" => "at_x", "render" => { "frame_url" => "https://f" } },
        "decision" => { "fill" => true }
      )
      allow(client).to receive(:create_placement).and_return(response)

      expect(facade.create_placement(job_type: "chat")).to be(response)
    end

    it "forwards keyword arguments to the client" do
      allow(client).to receive(:create_placement).and_return(nil_response)

      facade.create_placement(job_type: "chat", session_id: "sess_1")

      expect(client).to have_received(:create_placement).with(job_type: "chat", session_id: "sess_1")
    end

    it "swallows a Wavebird::Error and returns a synthetic no-fill" do
      allow(client).to receive(:create_placement).and_raise(Wavebird::TimeoutError, "boom")

      result = facade.create_placement(job_type: "chat")

      expect(result).to be_a(Wavebird::Types::PlacementResponse)
      expect(result).to be_no_fill
      expect(result.placement).to be_nil
    end

    it "reports a swallowed error through on_error and the logger" do
      logger = instance_spy(Logger)
      observed = []
      config.logger = logger
      config.on_error = ->(error) { observed << error }
      allow(client).to receive(:create_placement).and_raise(Wavebird::APIError, "upstream sad")

      facade.create_placement(job_type: "chat")

      expect(observed).to contain_exactly(an_instance_of(Wavebird::APIError))
      expect(logger).to have_received(:warn).with(/Wavebird::APIError: upstream sad/)
    end

    it "does not let an on_error observer that raises break the host flow" do
      config.on_error = ->(_error) { raise "observer blew up" }
      allow(client).to receive(:create_placement).and_raise(Wavebird::ConnectionError, "down")

      expect { facade.create_placement(job_type: "chat") }.not_to raise_error
    end

    it "does not swallow non-Wavebird errors" do
      allow(client).to receive(:create_placement).and_raise(ArgumentError, "bad call")

      expect { facade.create_placement(job_type: "chat") }.to raise_error(ArgumentError)
    end
  end

  describe "#record_beacon" do
    let(:required) { { slot_id: "slot_1", asset_token: "at_secret", event: "rendered" } }

    it "returns the client's result on success" do
      result = Wavebird::Types::BeaconResult.from_api("accepted" => true)
      allow(client).to receive(:record_beacon).and_return(result)

      expect(facade.record_beacon(**required)).to be(result)
    end

    it "swallows a Wavebird::Error and returns upstream's fail-silent acknowledgement" do
      allow(client).to receive(:record_beacon).and_raise(Wavebird::ConnectionError, "down")

      result = facade.record_beacon(**required)

      expect(result).to be_a(Wavebird::Types::BeaconResult)
      expect(result).not_to be_accepted
      expect(result.reason_code).to eq("SDK_FAIL_SILENT")
    end

    it "reports the swallowed error without leaking the asset token" do
      logger = instance_spy(Logger)
      config.logger = logger
      allow(client).to receive(:record_beacon).and_raise(Wavebird::TimeoutError, "slow")

      facade.record_beacon(**required)

      expect(logger).to have_received(:warn).with(/Wavebird::TimeoutError/)
      expect(logger).not_to have_received(:warn).with(/at_secret/)
    end
  end

  describe "#create_job" do
    let(:job) { Wavebird::Types::AcceptedJob.from_api("job_id" => "job_1", "slot_ids" => ["slot_1"], "status" => "accepted") }

    it "returns the client's job on success" do
      allow(client).to receive(:create_job).and_return(job)

      expect(facade.create_job(job_type: "chat")).to be(job)
    end

    it "forwards keyword arguments to the client" do
      allow(client).to receive(:create_job).and_return(job)

      facade.create_job(job_type: "chat", session_id: "sess_1")

      expect(client).to have_received(:create_job).with(job_type: "chat", session_id: "sess_1")
    end

    it "swallows a Wavebird::Error and returns nil (caller skips the poll)" do
      allow(client).to receive(:create_job).and_raise(Wavebird::APIError, "no")
      logger = instance_spy(Logger)
      config.logger = logger

      expect(facade.create_job(job_type: "chat")).to be_nil
      expect(logger).to have_received(:warn).with(/Wavebird::APIError/)
    end

    it "does not swallow non-Wavebird errors" do
      allow(client).to receive(:create_job).and_raise(ArgumentError, "bad")

      expect { facade.create_job(job_type: "chat") }.to raise_error(ArgumentError)
    end

    # Upstream answers a 429 with a value, not an error: createJob returns
    # {error: "rate_limit_exceeded", retry_after_ms} and logs a warning.
    context "when the API rate limits the request" do
      let(:rate_limited) { Wavebird::RateLimitedError.new("slow down", retry_after: 12.5) }

      it "returns a rate-limit outcome instead of nil" do
        allow(client).to receive(:create_job).and_raise(rate_limited)

        result = facade.create_job(job_type: "chat")

        expect(result).to be_a(Wavebird::Types::RateLimited)
        expect(result).to be_rate_limited
        expect(result.error).to eq("rate_limit_exceeded")
        expect(result.retry_after).to eq(12.5)
      end

      it "logs a warning naming the retry delay" do
        logger = instance_spy(Logger)
        config.logger = logger
        allow(client).to receive(:create_job).and_raise(rate_limited)

        facade.create_job(job_type: "chat")

        expect(logger).to have_received(:warn).with(/rate limited.*Retry after 12\.5s/)
      end

      it "omits the retry hint when the API sent no Retry-After" do
        logger = instance_spy(Logger)
        config.logger = logger
        allow(client).to receive(:create_job).and_raise(Wavebird::RateLimitedError.new("slow down"))

        facade.create_job(job_type: "chat")

        expect(logger).to have_received(:warn).with(/rate limited by the API\.\z/)
      end

      it "does not notify on_error, which is for failures" do
        observed = []
        config.on_error = ->(e) { observed << e }
        allow(client).to receive(:create_job).and_raise(rate_limited)

        facade.create_job(job_type: "chat")

        expect(observed).to be_empty
      end

      it "still answers rate_limited? false for an accepted job" do
        allow(client).to receive(:create_job).and_return(job)

        expect(facade.create_job(job_type: "chat")).not_to be_rate_limited
      end
    end
  end

  describe "#poll_decision" do
    it "returns the client's decision on success" do
      decision = Wavebird::Types::Decision.from_api("slot_id" => "slot_1", "status" => "ready", "fill" => false)
      allow(client).to receive(:poll_decision).and_return(decision)

      expect(facade.poll_decision("slot_1")).to be(decision)
    end

    it "forwards keyword arguments to the client" do
      allow(client).to receive(:poll_decision).and_return(nil)

      facade.poll_decision("slot_1", wait_ms: 0)

      expect(client).to have_received(:poll_decision).with("slot_1", wait_ms: 0)
    end

    it "swallows a Wavebird::Error and returns a pending decision for the slot" do
      allow(client).to receive(:poll_decision).and_raise(Wavebird::ConnectionError, "down")

      result = facade.poll_decision("slot_1")

      expect(result).to be_pending
      expect(result.slot_id).to eq("slot_1")
    end
  end

  describe "#await_decision" do
    it "returns the client's decision on success" do
      decision = Wavebird::Types::Decision.from_api("slot_id" => "slot_1", "status" => "ready", "fill" => true)
      allow(client).to receive(:await_decision).and_return(decision)

      expect(facade.await_decision("slot_1")).to be(decision)
    end

    # Upstream's fallbackDecision: the auction never reached a verdict, so the
    # result says "pending" rather than asserting a no-fill that never happened.
    it "swallows a Wavebird::Error and returns a synthetic pending decision" do
      allow(client).to receive(:await_decision).and_raise(Wavebird::DecisionTimeoutError, "slow")

      result = facade.await_decision("slot_1")

      expect(result).to be_a(Wavebird::Types::Decision)
      expect(result.slot_id).to eq("slot_1")
      expect(result).to be_pending
      expect(result).not_to be_fill
      expect(result.fill).to be_nil
    end

    it "reports the swallowed error through on_error and the logger" do
      observed = []
      logger = instance_spy(Logger)
      config.on_error = ->(e) { observed << e }
      config.logger = logger
      allow(client).to receive(:await_decision).and_raise(Wavebird::ConnectionError, "down")

      facade.await_decision("slot_1")

      expect(observed).to contain_exactly(an_instance_of(Wavebird::ConnectionError))
      expect(logger).to have_received(:warn).with(/Wavebird::ConnectionError/)
    end

    it "does not swallow non-Wavebird errors" do
      allow(client).to receive(:await_decision).and_raise(ArgumentError, "bad")

      expect { facade.await_decision("slot_1") }.to raise_error(ArgumentError)
    end
  end

  # Upstream's reportGeneration is documented `@throws Never` and is called from
  # inside the host's generation loop; a raising-only version would let the ad
  # path take a chat turn down.
  describe "#report_generation" do
    it "returns the client's acknowledgement on success" do
      allow(client).to receive(:report_generation).and_return(true)

      expect(facade.report_generation("job_1", "finished")).to be(true)
    end

    it "forwards positional and keyword arguments to the client" do
      allow(client).to receive(:report_generation).and_return(true)

      facade.report_generation("job_1", "started", model_id: "gpt-x")

      expect(client).to have_received(:report_generation).with("job_1", "started", model_id: "gpt-x")
    end

    it "swallows a Wavebird::Error and returns false" do
      logger = instance_spy(Logger)
      config.logger = logger
      allow(client).to receive(:report_generation).and_raise(Wavebird::TimeoutError, "slow")

      expect(facade.report_generation("job_1", "finished")).to be(false)
      expect(logger).to have_received(:warn).with(/Wavebird::TimeoutError/)
    end

    it "does not swallow an unknown event, which is a caller bug" do
      allow(client).to receive(:report_generation).and_raise(ArgumentError, "event must be one of")

      expect { facade.report_generation("job_1", "nope") }.to raise_error(ArgumentError)
    end
  end

  describe "#record_consent" do
    it "returns the client's state on success" do
      state = Wavebird::Types::ConsentState.from_api("decision" => "basic")
      allow(client).to receive(:record_consent).and_return(state)

      expect(facade.record_consent(decision: "basic", source: "publisher_custom")).to be(state)
    end

    it "swallows a Wavebird::Error and returns nil" do
      allow(client).to receive(:record_consent).and_raise(Wavebird::APIError, "no")

      expect(facade.record_consent(decision: "basic", source: "publisher_custom")).to be_nil
    end
  end

  describe "#activate_browser" do
    it "returns the client's activation on success" do
      activation = Wavebird::Types::BrowserActivation.from_api("activation_token" => "tok", "expires_at_ms" => 1)
      allow(client).to receive(:activate_browser).and_return(activation)

      expect(facade.activate_browser(origin: "https://app.example")).to be(activation)
    end

    it "swallows a Wavebird::Error and returns nil" do
      allow(client).to receive(:activate_browser).and_raise(Wavebird::ConfigurationError, "no key")

      expect(facade.activate_browser(origin: "https://app.example")).to be_nil
    end
  end

  describe "#project_config" do
    it "returns the client's config on success" do
      project = Wavebird::Types::ProjectConfig.from_api("features" => {})
      allow(client).to receive(:project_config).and_return(project)

      expect(facade.project_config).to be(project)
    end

    it "swallows a Wavebird::Error and returns nil" do
      allow(client).to receive(:project_config).and_raise(Wavebird::NotFoundError, "gone")

      expect(facade.project_config).to be_nil
    end
  end

  describe "defaults" do
    it "wraps a real Client against the global configuration by default" do
      facade = described_class.new
      expect(facade.client).to be_a(Wavebird::Client)
      expect(facade.config).to be(Wavebird.configuration)
    ensure
      Wavebird.reset_configuration!
    end
  end

  # A minimal no-fill response for delegation tests that don't care about shape.
  def nil_response
    Wavebird::Types::PlacementResponse.from_api("status" => "no_fill", "placement" => nil, "decision" => nil)
  end
end
