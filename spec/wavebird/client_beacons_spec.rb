# frozen_string_literal: true

RSpec.describe Wavebird::Client, "beacons, consent and browser activation" do
  include_context "with a configured client"

  describe "#record_beacon" do
    let(:beacons_url) { "#{api_base}/v1/beacons" }
    let(:required) { { slot_id: "slot_123", asset_token: "at_secret_proof", event: "rendered" } }

    it "posts the canonical body and returns the acknowledgement" do
      stub = stub_request(:post, beacons_url)
             .with(body: hash_including("beacon_id" => "b_1", "slot_id" => "slot_123",
                                        "asset_token" => "at_secret_proof", "event" => "rendered"))
             .to_return(status: 200, body: JSON.generate({ "ok" => true, "accepted" => true,
                                                           "duplicate" => false, "reason_code" => "OK" }))

      result = client.record_beacon(**required, beacon_id: "b_1")

      expect(stub).to have_been_requested
      expect(result).to be_accepted
      expect(result).not_to be_duplicate
    end

    it "generates a uuid beacon_id when none is given" do
      stub = stub_request(:post, beacons_url)
             .with(body: hash_including("beacon_id" => match(/\A[0-9a-f-]{36}\z/)))
             .to_return(status: 204, body: "")

      client.record_beacon(**required)

      expect(stub).to have_been_requested
    end

    it "defaults occurred_at to now as a UTC ISO8601 timestamp with milliseconds" do
      stub = stub_request(:post, beacons_url)
             .with(body: hash_including("occurred_at" => match(/\A\d{4}-\d{2}-\d{2}T[\d:.]+Z\z/)))
             .to_return(status: 204, body: "")

      client.record_beacon(**required)

      expect(stub).to have_been_requested
    end

    it "passes a caller-supplied timestamp through as UTC ISO8601" do
      stub = stub_request(:post, beacons_url)
             .with(body: hash_including("occurred_at" => "2026-07-18T10:30:00.000Z"))
             .to_return(status: 204, body: "")

      client.record_beacon(**required, occurred_at: Time.utc(2026, 7, 18, 10, 30, 0))

      expect(stub).to have_been_requested
    end

    it "leaves an already-formatted timestamp string untouched" do
      stub = stub_request(:post, beacons_url)
             .with(body: hash_including("occurred_at" => "2026-07-18T10:30:00.000Z"))
             .to_return(status: 204, body: "")

      client.record_beacon(**required, occurred_at: "2026-07-18T10:30:00.000Z")

      expect(stub).to have_been_requested
    end

    it "treats a 204 with an empty body as accepted (upstream behavior)" do
      stub_request(:post, beacons_url).to_return(status: 204, body: "")

      result = client.record_beacon(**required)

      expect(result).to be_accepted
      expect(result.reason_code).to eq("OK")
    end

    it "reports an idempotent duplicate as a success" do
      stub_request(:post, beacons_url)
        .to_return(status: 200, body: JSON.generate({ "accepted" => true, "duplicate" => true,
                                                      "reason_code" => "DUPLICATE" }))

      result = client.record_beacon(**required)

      expect(result).to be_accepted
      expect(result).to be_duplicate
    end

    it "omits metadata when not supplied" do
      stub = stub_request(:post, beacons_url)
             .with { |req| !JSON.parse(req.body).key?("metadata") }
             .to_return(status: 204, body: "")

      client.record_beacon(**required)

      expect(stub).to have_been_requested
    end

    it "never leaks the asset token into inspection output" do
      stub_request(:post, beacons_url).to_return(status: 204, body: "")

      expect(client.record_beacon(**required).inspect).not_to include("at_secret_proof")
    end

    describe "event validation" do
      Wavebird::Client::BEACON_EVENTS.each do |event|
        it "accepts the canonical #{event.inspect} event" do
          stub = stub_request(:post, beacons_url)
                 .with(body: hash_including("event" => event))
                 .to_return(status: 204, body: "")

          client.record_beacon(**required, event: event)

          expect(stub).to have_been_requested
        end
      end

      it "accepts a symbol event and emits it canonically" do
        stub = stub_request(:post, beacons_url)
               .with(body: hash_including("event" => "clicked"))
               .to_return(status: 204, body: "")

        client.record_beacon(**required, event: :clicked)

        expect(stub).to have_been_requested
      end

      # Upstream maps unknown types to null and falls back to the legacy wrapper
      # beacon endpoint; the canonical-only client has no such fallback, so it
      # must reject locally rather than emit an unroutable event.
      it "rejects an unknown event before any request is made" do
        stub = stub_request(:post, beacons_url)

        expect { client.record_beacon(**required, event: "visible_ended") }
          .to raise_error(ArgumentError, /event must be one of rendered\|visible\|/)
        expect(stub).not_to have_been_requested
      end

      it "does not put the asset token on the wire when the event is invalid" do
        stub = stub_request(:post, beacons_url)

        expect { client.record_beacon(**required, event: "typo") }.to raise_error(ArgumentError)
        expect(stub).not_to have_been_requested
      end
    end
  end

  describe "#record_consent" do
    let(:consent_url) { "#{api_base}/v1/consent" }

    it "posts the canonical consent body" do
      stub = stub_request(:post, consent_url)
             .with(body: { client_id: "wbproj_spec", session_id: "sess_1", decision: "personalized",
                           source: "wavebird_dialog", purposes: { "analytics" => true } })
             .to_return(status: 200, body: JSON.generate({ "decision" => "personalized",
                                                           "source" => "wavebird_dialog" }))

      state = client.record_consent(decision: "personalized", source: "wavebird_dialog",
                                    session_id: "sess_1", purposes: { "analytics" => true })

      expect(stub).to have_been_requested
      expect(state.decision).to eq("personalized")
    end

    %w[publisher custom_dialog].each do |alias_source|
      it "canonicalizes the #{alias_source.inspect} input alias to publisher_custom" do
        stub = stub_request(:post, consent_url)
               .with(body: hash_including("source" => "publisher_custom"))
               .to_return(status: 200, body: JSON.generate({ "source" => "publisher_custom" }))

        client.record_consent(decision: "basic", source: alias_source)

        expect(stub).to have_been_requested.once
      end
    end

    it "passes an already-canonical source through unchanged" do
      stub = stub_request(:post, consent_url)
             .with(body: hash_including("source" => "server_sync"))
             .to_return(status: 200, body: JSON.generate({ "source" => "server_sync" }))

      client.record_consent(decision: "custom", source: :server_sync)

      expect(stub).to have_been_requested
    end

    it "tolerates an empty acknowledgement body" do
      stub_request(:post, consent_url).to_return(status: 204, body: "")

      expect(client.record_consent(decision: "basic", source: "server_sync").decision).to be_nil
    end

    describe "enum validation" do
      Wavebird::Client::CONSENT_DECISIONS.each do |decision|
        it "accepts the canonical #{decision.inspect} decision" do
          stub = stub_request(:post, consent_url)
                 .with(body: hash_including("decision" => decision))
                 .to_return(status: 204, body: "")

          client.record_consent(decision: decision, source: "server_sync")

          expect(stub).to have_been_requested
        end
      end

      it "rejects an unknown decision before any request is made" do
        stub = stub_request(:post, consent_url)

        expect { client.record_consent(decision: "everything", source: "server_sync") }
          .to raise_error(ArgumentError, /decision must be one of personalized\|basic\|custom/)
        expect(stub).not_to have_been_requested
      end

      it "rejects an unknown source before any request is made" do
        stub = stub_request(:post, consent_url)

        expect { client.record_consent(decision: "basic", source: "carrier_pigeon") }
          .to raise_error(ArgumentError, /source must be one of publisher_custom\|/)
        expect(stub).not_to have_been_requested
      end
    end
  end

  describe "#activate_browser" do
    let(:activate_url) { "#{api_base}/v1/browser/activate" }
    let(:activation_body) do
      { "activation_token" => "act_token_1", "expires_at_ms" => 1_800_000_000_000 }
    end

    before { config.publishable_key = "pk_test_spec_placeholder" }

    it "sends the publishable key and Origin without the secret key" do
      stub = stub_request(:post, activate_url)
             .with(body: { publishable_key: "pk_test_spec_placeholder" },
                   headers: { "Origin" => "https://app.example.com" }) do |req|
               !req.headers.key?("Authorization")
             end
             .to_return(status: 200, body: JSON.generate(activation_body))

      activation = client.activate_browser(origin: "https://app.example.com")

      expect(stub).to have_been_requested
      expect(activation.activation_token).to eq("act_token_1")
    end

    it "resolves a callable publishable key per request (getApiKey parity)" do
      calls = 0
      stub_request(:post, activate_url).to_return(status: 200, body: JSON.generate(activation_body))

      client.activate_browser(origin: "https://app.example.com",
                              publishable_key: -> { calls += 1 and "pk_rotated" })

      expect(calls).to eq(1)
    end

    it "raises ConfigurationError when no publishable key is configured" do
      config.publishable_key = nil

      expect { client.activate_browser(origin: "https://app.example.com") }
        .to raise_error(Wavebird::ConfigurationError, /publishable_key is not configured/)
    end

    it "rejects a response without a usable activation token" do
      stub_request(:post, activate_url)
        .to_return(status: 200, body: JSON.generate({ "activation_token" => "  ", "expires_at_ms" => 1 }))

      expect { client.activate_browser(origin: "https://app.example.com") }
        .to raise_error(Wavebird::InvalidResponseError, /Invalid activation response/)
    end

    it "rejects a non-object activation response" do
      stub_request(:post, activate_url).to_return(status: 200, body: JSON.generate(["nope"]))

      expect { client.activate_browser(origin: "https://app.example.com") }
        .to raise_error(Wavebird::InvalidResponseError, /Invalid activation response/)
    end

    it "rejects a response with a non-numeric expiry" do
      stub_request(:post, activate_url)
        .to_return(status: 200, body: JSON.generate({ "activation_token" => "act_1", "expires_at_ms" => "soon" }))

      expect { client.activate_browser(origin: "https://app.example.com") }
        .to raise_error(Wavebird::InvalidResponseError)
    end

    it "never leaks the activation token into inspection output" do
      stub_request(:post, activate_url).to_return(status: 200, body: JSON.generate(activation_body))

      expect(client.activate_browser(origin: "https://app.example.com").inspect).not_to include("act_token_1")
    end
  end
end
