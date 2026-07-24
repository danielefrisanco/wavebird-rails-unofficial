# frozen_string_literal: true

RSpec.describe Wavebird::Client, "request plumbing" do
  include_context "with a configured client"

  # project_config is the simplest GET; used here to exercise shared plumbing.
  let(:config_url) { "#{api_base}/v1/projects/wbproj_spec/config" }

  describe "request headers" do
    it "sends bearer auth, accept, user agent and the wrapper version header" do
      stub = stub_request(:get, config_url)
             .with(headers: { "Authorization" => "Bearer sk_test_spec_placeholder",
                              "Accept" => "application/json",
                              "User-Agent" => "wavebird-rails/#{Wavebird::VERSION}",
                              "X-Csl-Wrapper-Version" => "wavebird-rails/#{Wavebird::VERSION}" })
             .to_return(status: 200, body: "{}")

      client.project_config

      expect(stub).to have_been_requested
    end

    it "resolves a callable secret key immediately before each request" do
      keys = %w[sk_test_first sk_test_second]
      config.secret_key = -> { keys.shift }
      stub_request(:get, config_url).to_return(status: 200, body: "{}")

      client.project_config
      client.project_config

      expect(a_request(:get, config_url).with(headers: { "Authorization" => "Bearer sk_test_first" }))
        .to have_been_made.once
      expect(a_request(:get, config_url).with(headers: { "Authorization" => "Bearer sk_test_second" }))
        .to have_been_made.once
    end

    it "raises ConfigurationError when the secret key is blank" do
      config.secret_key = "  "

      expect { client.project_config }.to raise_error(Wavebird::ConfigurationError, /secret_key/)
    end
  end

  describe "error envelope mapping" do
    {
      "unauthorized" => [401, Wavebird::UnauthorizedError],
      "forbidden" => [403, Wavebird::ForbiddenError],
      "validation_error" => [400, Wavebird::ValidationError],
      "not_found" => [404, Wavebird::NotFoundError]
    }.each do |code, (status, klass)|
      it "raises #{klass} for #{code}" do
        stub_request(:get, config_url).to_return(
          status: status,
          body: JSON.generate(error: code, message: "#{code} happened",
                              docs_url: "https://docs.wavebird.ai/errors##{code}", request_id: "req_1")
        )

        expect { client.project_config }.to raise_error(klass) do |error|
          expect(error).to have_attributes(
            message: "#{code} happened", code: code, request_id: "req_1",
            docs_url: "https://docs.wavebird.ai/errors##{code}", http_status: status
          )
        end
      end
    end

    it "raises APIError for unknown codes" do
      stub_request(:get, config_url).to_return(status: 502, body: JSON.generate(error: "upstream_sad"))

      expect { client.project_config }.to raise_error(Wavebird::APIError) do |error|
        expect(error.code).to eq("upstream_sad")
        expect(error).not_to be_a(Wavebird::UnauthorizedError)
      end
    end

    it "falls back to a generic message and the X-Request-Id header without an envelope" do
      stub_request(:get, config_url).to_return(status: 500, body: "<html>oops</html>",
                                               headers: { "X-Request-Id" => "req_hdr" })

      expect { client.project_config }.to raise_error(Wavebird::APIError) do |error|
        expect(error.message).to include("status 500")
        expect(error.request_id).to eq("req_hdr")
        expect(error.code).to be_nil
      end
    end

    it "treats a non-object error body as an empty envelope" do
      stub_request(:get, config_url).to_return(status: 500, body: "[1,2]")

      expect { client.project_config }.to raise_error(Wavebird::APIError)
    end

    it "treats redirects as errors like upstream" do
      stub_request(:get, config_url).to_return(status: 302, body: "", headers: { "Location" => "https://elsewhere" })

      expect { client.project_config }.to raise_error(Wavebird::APIError) do |error|
        expect(error.http_status).to eq(302)
      end
    end
  end

  describe "rate limiting" do
    it "raises RateLimitedError with delta-seconds Retry-After" do
      stub_request(:get, config_url).to_return(
        status: 429, headers: { "Retry-After" => "2" },
        body: JSON.generate(error: "rate_limited", message: "slow down")
      )

      expect { client.project_config }.to raise_error(Wavebird::RateLimitedError) do |error|
        expect(error.retry_after).to eq(2.0)
        expect(error.http_status).to eq(429)
      end
    end

    it "parses an HTTP-date Retry-After relative to now" do
      stub_request(:get, config_url).to_return(
        status: 429, headers: { "Retry-After" => (Time.now + 30).httpdate },
        body: JSON.generate(error: "rate_limited")
      )

      expect { client.project_config }.to raise_error(Wavebird::RateLimitedError) do |error|
        expect(error.retry_after).to be_between(25, 30)
      end
    end

    it "clamps past HTTP-dates to zero" do
      stub_request(:get, config_url).to_return(
        status: 429, headers: { "Retry-After" => (Time.now - 60).httpdate },
        body: JSON.generate(error: "rate_limited")
      )

      expect { client.project_config }.to raise_error(Wavebird::RateLimitedError) do |error|
        expect(error.retry_after).to eq(0.0)
      end
    end

    it "defaults to one second for a missing or invalid Retry-After" do
      rate_limited = JSON.generate(error: "rate_limited")
      stub_request(:get, config_url)
        .to_return(status: 429, body: rate_limited).then
        .to_return(status: 429, headers: { "Retry-After" => "soon" }, body: rate_limited)

      2.times do
        expect { client.project_config }.to raise_error(Wavebird::RateLimitedError) do |error|
          expect(error.retry_after).to eq(1.0)
        end
      end
    end

    it "treats a bodiless 429 as rate limited (upstream keys off the status)" do
      stub_request(:get, config_url).to_return(status: 429, body: "", headers: { "Retry-After" => "-3" })

      expect { client.project_config }.to raise_error(Wavebird::RateLimitedError) do |error|
        expect(error.retry_after).to eq(1.0)
        expect(error.code).to be_nil
      end
    end
  end

  describe "transport errors" do
    it "raises Wavebird::TimeoutError on read timeouts" do
      stub_request(:get, config_url).to_raise(Faraday::TimeoutError)

      expect { client.project_config }.to raise_error(Wavebird::TimeoutError, /timed out after #{config.timeout_ms}ms/)
    end

    # Adapters surface connect-phase timeouts as ConnectionFailed wrapping a
    # Timeout::Error (WebMock's to_timeout reproduces this via Net::OpenTimeout),
    # but upstream still classifies them as timeouts.
    it "raises Wavebird::TimeoutError when a connect timeout arrives as ConnectionFailed" do
      stub_request(:get, config_url).to_timeout

      expect { client.project_config }.to raise_error(Wavebird::TimeoutError, /timed out after #{config.timeout_ms}ms/)
    end

    it "raises Wavebird::TimeoutError for an ETIMEDOUT cause" do
      stub_request(:get, config_url).to_raise(Errno::ETIMEDOUT)

      expect { client.project_config }.to raise_error(Wavebird::TimeoutError)
    end

    it "raises Wavebird::ConnectionError on connection failures" do
      stub_request(:get, config_url).to_raise(Errno::ECONNREFUSED)

      expect { client.project_config }.to raise_error(Wavebird::ConnectionError)
    end

    it "raises Wavebird::ConnectionError on SSL failures" do
      stub_request(:get, config_url).to_raise(Faraday::SSLError)

      expect { client.project_config }.to raise_error(Wavebird::ConnectionError)
    end
  end

  describe "response body handling" do
    it "rejects invalid JSON in a success response" do
      stub_request(:get, config_url).to_return(status: 200, body: "not json")

      expect { client.project_config }.to raise_error(Wavebird::InvalidResponseError, /parsed as JSON/)
    end

    it "rejects oversized bodies (upstream 64 KiB cap)" do
      stub_request(:get, config_url).to_return(status: 200, body: "[#{'1,' * 40_000}1]")

      expect { client.project_config }.to raise_error(Wavebird::InvalidResponseError, /exceeds/)
    end
  end

  describe "#project_config" do
    it "returns the server-owned config, readable by string or symbol key" do
      stub_request(:get, config_url)
        .to_return(status: 200, body: JSON.generate({ "formats" => %w[banner native], "sandbox" => true }))

      project = client.project_config

      expect(project[:formats]).to eq(%w[banner native])
      expect(project["sandbox"]).to be(true)
    end

    it "accepts a per-call client_id and escapes it in the path" do
      stub = stub_request(:get, "#{api_base}/v1/projects/wbproj%2Fother/config")
             .to_return(status: 200, body: JSON.generate({}))

      client.project_config(client_id: "wbproj/other")

      expect(stub).to have_been_requested
    end

    it "raises ConfigurationError when no client_id is configured" do
      config.client_id = nil

      expect { client.project_config }.to raise_error(Wavebird::ConfigurationError, /client_id is not configured/)
    end

    it "tolerates an empty config body" do
      stub_request(:get, config_url).to_return(status: 204, body: "")

      expect(client.project_config[:anything]).to be_nil
    end
  end

  describe "defaults" do
    it "uses the global configuration by default" do
      expect(described_class.new.config).to be(Wavebird.configuration)
    ensure
      Wavebird.reset_configuration!
    end
  end
end
