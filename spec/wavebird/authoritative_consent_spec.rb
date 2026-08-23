# frozen_string_literal: true

# The gate that made the gem's browser integration inert (plan v3). wavebird's
# hosted render.js refuses every turn whose `authoritative_consent` it does not
# accept -- silently, with no request and no error -- so the cost of getting this
# object wrong is "no ads, no explanation". Every rule asserted here mirrors
# `consentAllowsAdActivity` in docs/upstream/render-js-snapshot-2026-08-23.js.
RSpec.describe Wavebird::AuthoritativeConsent do
  subject(:resolved) { described_class.resolve(config, now_ms: now_ms) }

  let(:now_ms) { 1_700_000_000_000 }
  let(:logger) { instance_double(Logger, warn: nil) }
  let(:config) { Wavebird::Configuration.new.tap { |c| c.logger = logger } }
  let(:valid) { { lifecycle_state: "granted", expires_at_ms: now_ms + 60_000 } }

  after { Wavebird::Deprecation.reset! }

  describe "when unset" do
    it "resolves to nil" do
      expect(resolved).to be_nil
    end

    it "says so once per process, not on every page render" do
      3.times { described_class.resolve(config, now_ms: now_ms) }

      expect(logger).to have_received(:warn).once.with(/authoritative_consent is not set/)
    end
  end

  describe "a valid grant" do
    before { config.authoritative_consent = -> { valid } }

    it "fills in the bookkeeping fields the renderer checks but does not interpret" do
      expect(resolved).to eq(lifecycle_state: "granted", revision: 1,
                             updated_at_ms: now_ms, expires_at_ms: now_ms + 60_000)
    end

    it "accepts a plain hash as well as a callable" do
      config.authoritative_consent = valid

      expect(resolved[:lifecycle_state]).to eq("granted")
    end

    it "accepts string keys" do
      config.authoritative_consent = -> { { "lifecycle_state" => "granted", "expires_at_ms" => now_ms + 1 } }

      expect(resolved[:lifecycle_state]).to eq("granted")
    end

    it "keeps a caller-supplied revision and updated_at_ms" do
      config.authoritative_consent = -> { valid.merge(revision: 7, updated_at_ms: 42) }

      expect(resolved).to include(revision: 7, updated_at_ms: 42)
    end

    it "sends exactly the four fields the renderer reads and nothing else" do
      config.authoritative_consent = -> { valid.merge(user_email: "someone@example.com", notes: "x") }

      # This object is serialised into the page. Anything a host puts alongside
      # the four fields would be published with it, so the shape is a whitelist.
      expect(resolved.keys).to contain_exactly(:lifecycle_state, :revision, :updated_at_ms, :expires_at_ms)
    end

    it "is resolved fresh on every call, so a withdrawal takes effect" do
      states = %w[granted denied]
      config.authoritative_consent = -> { valid.merge(lifecycle_state: states.shift) }

      expect(described_class.resolve(config, now_ms: now_ms)).not_to be_nil
      expect(described_class.resolve(config, now_ms: now_ms)).to be_nil
    end
  end

  # A visitor who declined is not a misconfiguration. The slot stays empty and
  # nothing is logged -- that is the system working.
  describe "a state other than granted" do
    before { config.authoritative_consent = -> { valid.merge(lifecycle_state: "denied") } }

    it "resolves to nil" do
      expect(resolved).to be_nil
    end

    it "says nothing, because declining is a normal answer" do
      resolved

      expect(logger).not_to have_received(:warn)
    end
  end

  # These are host bugs, and the renderer would swallow them, so the gem reports
  # them every time rather than once: a persistently broken consent config means
  # no revenue at all, and it should stay noisy (#028's reasoning).
  describe "an object the renderer would reject" do
    {
      "no lifecycle_state" => { expires_at_ms: 1_700_000_060_000 },
      "a non-integer revision" => { lifecycle_state: "granted", revision: "1",
                                    expires_at_ms: 1_700_000_060_000 },
      "revision below 1" => { lifecycle_state: "granted", revision: 0,
                              expires_at_ms: 1_700_000_060_000 },
      "a non-integer expires_at_ms" => { lifecycle_state: "granted", expires_at_ms: "soon" },
      "an expiry in the past" => { lifecycle_state: "granted", expires_at_ms: 1_699_999_000_000 }
    }.each do |label, object|
      it "rejects and reports #{label}" do
        config.authoritative_consent = -> { object }

        expect(described_class.resolve(config, now_ms: now_ms)).to be_nil
        expect(logger).to have_received(:warn).with(/authoritative_consent/)
      end
    end

    it "reports every time, so a broken config does not go quiet" do
      config.authoritative_consent = -> { { lifecycle_state: "granted", expires_at_ms: "soon" } }

      2.times { described_class.resolve(config, now_ms: now_ms) }

      expect(logger).to have_received(:warn).twice
    end

    it "treats a value that is not hash-like as absent" do
      config.authoritative_consent = -> { "granted" }

      expect(resolved).to be_nil
    end

    # Responds to #to_h but blows up on conversion -- the case a `respond_to?`
    # guard alone does not cover.
    it "treats a value whose to_h raises as absent" do
      config.authoritative_consent = -> { [1, 2] }

      expect { resolved }.not_to raise_error
      expect(resolved).to be_nil
    end
  end

  describe "when the resolver raises" do
    before { config.authoritative_consent = -> { raise "consent store down" } }

    # #003: the ad path never breaks the host's flow. A consent store outage
    # costs the ad, not the chat turn.
    it "does not propagate" do
      expect { resolved }.not_to raise_error
    end

    it "resolves to nil and reports what happened" do
      expect(resolved).to be_nil
      expect(logger).to have_received(:warn).with(/raised RuntimeError: consent store down/)
    end
  end

  it "works with no logger configured" do
    config.logger = nil
    config.authoritative_consent = -> { { lifecycle_state: "granted", expires_at_ms: "bad" } }

    expect { described_class.resolve(config, now_ms: now_ms) }.not_to raise_error
  end

  it "defaults updated_at_ms from the real clock when none is injected" do
    config.authoritative_consent = -> { valid.merge(expires_at_ms: (Time.now.to_f * 1000).to_i + 60_000) }

    expect(described_class.resolve(config)[:updated_at_ms]).to be_within(5_000).of((Time.now.to_f * 1000).to_i)
  end
end
