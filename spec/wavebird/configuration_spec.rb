# frozen_string_literal: true

RSpec.describe Wavebird::Configuration do
  subject(:config) { described_class.new }

  describe "defaults (parity with upstream WavebirdClientOptions)" do
    it "targets the production API over HTTPS" do
      expect(config.api_base_url).to eq("https://api.wavebird.ai")
    end

    it "mirrors upstream numeric defaults" do
      expect(config.timeout_ms).to eq(2_000)
      expect(config.decision_timeout_ms).to eq(30_000)
      expect(config.long_poll_wait_ms).to eq(1_500)
      expect(config.short_poll_interval_ms).to eq(250)
    end

    it "identifies this wrapper in the version header value" do
      expect(config.wrapper_version).to eq("wavebird-rails/#{Wavebird::VERSION}")
    end

    it "leaves optional settings unset" do
      expect(
        [config.secret_key, config.client_id, config.default_slot_hint, config.default_overrides,
         config.default_publisher, config.on_error, config.logger]
      ).to all(be_nil)
    end
  end

  describe "numeric clamping (ports upstream clampInt)" do
    {
      timeout_ms: [250, 30_000, 2_000],
      decision_timeout_ms: [1_000, 60_000, 30_000],
      long_poll_wait_ms: [0, 5_000, 1_500],
      short_poll_interval_ms: [100, 5_000, 250]
    }.each do |option, (min, max, default)|
      describe "##{option}=" do
        it "clamps below #{min} up to #{min}" do
          config.public_send(:"#{option}=", min - 1)
          expect(config.public_send(option)).to eq(min)
        end

        it "clamps above #{max} down to #{max}" do
          config.public_send(:"#{option}=", max + 1)
          expect(config.public_send(option)).to eq(max)
        end

        it "floors in-range floats" do
          config.public_send(:"#{option}=", min + 1.9)
          expect(config.public_send(option)).to eq(min + 1)
        end

        it "resolves nil to the default #{default}" do
          config.public_send(:"#{option}=", nil)
          expect(config.public_send(option)).to eq(default)
        end

        it "rejects non-numeric values" do
          expect { config.public_send(:"#{option}=", "fast") }
            .to raise_error(Wavebird::ConfigurationError, /#{option} must be a number/)
        end

        it "rejects non-finite values" do
          expect { config.public_send(:"#{option}=", Float::INFINITY) }
            .to raise_error(Wavebird::ConfigurationError, /#{option} must be a number/)
        end
      end
    end
  end

  describe "#api_base_url= (ports upstream normalizeBaseUrl)" do
    it "accepts HTTPS URLs and strips trailing slashes" do
      config.api_base_url = "https://sandbox.wavebird.ai/"
      expect(config.api_base_url).to eq("https://sandbox.wavebird.ai")
    end

    %w[localhost 127.0.0.1 [::1]].each do |host|
      it "allows plain HTTP for #{host}" do
        config.api_base_url = "http://#{host}:3000"
        expect(config.api_base_url).to eq("http://#{host}:3000")
      end
    end

    it "rejects plain HTTP for remote hosts" do
      expect { config.api_base_url = "http://api.wavebird.ai" }
        .to raise_error(Wavebird::ConfigurationError, /must use HTTPS/)
    end

    it "rejects non-http(s) schemes" do
      expect { config.api_base_url = "ftp://api.wavebird.ai" }
        .to raise_error(Wavebird::ConfigurationError, /http\(s\) URL/)
    end

    it "rejects strings that are not URLs" do
      expect { config.api_base_url = "not a url" }
        .to raise_error(Wavebird::ConfigurationError, /http\(s\) URL|not a valid URL/)
    end

    it "rejects nil" do
      expect { config.api_base_url = nil }
        .to raise_error(Wavebird::ConfigurationError, /http\(s\) URL/)
    end
  end

  describe "#resolved_secret_key" do
    it "returns a static key as-is" do
      config.secret_key = "sk_test_abc"
      expect(config.resolved_secret_key).to eq("sk_test_abc")
    end

    it "calls a callable key per read (parity with upstream getApiKey)" do
      keys = %w[sk_test_first sk_test_second].each
      config.secret_key = -> { keys.next }

      expect(config.resolved_secret_key).to eq("sk_test_first")
      expect(config.resolved_secret_key).to eq("sk_test_second")
    end
  end

  describe "#validate!" do
    before do
      config.secret_key = "sk_test_abc"
      config.client_id = "wbproj_123"
    end

    it "returns self when usable" do
      expect(config.validate!).to be(config)
    end

    [nil, "", "   "].each do |blank|
      it "raises when secret_key is #{blank.inspect}" do
        config.secret_key = blank
        expect { config.validate! }.to raise_error(Wavebird::ConfigurationError, /secret_key/)
      end
    end

    it "raises when a callable secret_key resolves blank" do
      config.secret_key = -> { "" }
      expect { config.validate! }.to raise_error(Wavebird::ConfigurationError, /secret_key/)
    end

    [nil, "", "   "].each do |blank|
      it "raises when client_id is #{blank.inspect}" do
        config.client_id = blank
        expect { config.validate! }.to raise_error(Wavebird::ConfigurationError, /client_id/)
      end
    end
  end

  describe "secret redaction" do
    it "never includes the secret key in #inspect" do
      config.secret_key = "sk_live_super_secret"
      expect(config.inspect).not_to include("sk_live_super_secret")
      expect(config.inspect).to include("[REDACTED]")
    end

    it "never includes the secret key in #to_s" do
      config.secret_key = "sk_live_super_secret"
      expect(config.to_s).not_to include("sk_live_super_secret")
    end

    it "shows nil when no secret key is set" do
      expect(config.inspect).to include("secret_key=nil")
    end
  end

  describe "global access via Wavebird.configure" do
    after { Wavebird.reset_configuration! }

    it "yields and memoizes the global configuration" do
      returned = Wavebird.configure { |c| c.client_id = "wbproj_123" }

      expect(returned).to be(Wavebird.configuration)
      expect(Wavebird.configuration.client_id).to eq("wbproj_123")
    end

    it "resets with reset_configuration!" do
      Wavebird.configure { |c| c.client_id = "wbproj_123" }
      Wavebird.reset_configuration!

      expect(Wavebird.configuration.client_id).to be_nil
    end
  end
end
