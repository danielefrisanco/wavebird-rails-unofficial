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

    it "swallows a Wavebird::Error and returns nil" do
      allow(client).to receive(:record_beacon).and_raise(Wavebird::ConnectionError, "down")

      expect(facade.record_beacon(**required)).to be_nil
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
