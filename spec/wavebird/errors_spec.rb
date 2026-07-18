# frozen_string_literal: true

RSpec.describe Wavebird::Error do
  it "exposes the full error envelope" do
    error = described_class.new(
      "boom", code: "unauthorized", request_id: "req_123", docs_url: "https://wavebird.ai/api/reference/errors",
              http_status: 401
    )

    expect(error.message).to eq("boom")
    expect(error.code).to eq("unauthorized")
    expect(error.request_id).to eq("req_123")
    expect(error.docs_url).to eq("https://wavebird.ai/api/reference/errors")
    expect(error.http_status).to eq(401)
  end

  it "defaults envelope fields to nil" do
    error = described_class.new("boom")

    expect([error.code, error.request_id, error.docs_url, error.http_status]).to all(be_nil)
  end

  describe ".class_for" do
    {
      "unauthorized" => Wavebird::UnauthorizedError,
      "forbidden" => Wavebird::ForbiddenError,
      "rate_limited" => Wavebird::RateLimitedError,
      "validation_error" => Wavebird::ValidationError,
      "not_found" => Wavebird::NotFoundError
    }.each do |code, klass|
      it "maps #{code.inspect} to #{klass}" do
        expect(described_class.class_for(code)).to eq(klass)
      end
    end

    it "falls back to APIError for unknown codes" do
      expect(described_class.class_for("mystery_code")).to eq(Wavebird::APIError)
    end

    it "falls back to APIError for nil" do
      expect(described_class.class_for(nil)).to eq(Wavebird::APIError)
    end
  end

  describe "hierarchy" do
    it "keeps every API error under APIError under Error" do
      described_class::CODE_CLASSES.each_value do |klass|
        expect(klass.ancestors).to include(Wavebird::APIError, described_class, StandardError)
      end
    end

    it "keeps transport and configuration errors under Error" do
      expect(Wavebird::ConnectionError.superclass).to eq(described_class)
      expect(Wavebird::TimeoutError.superclass).to eq(Wavebird::ConnectionError)
      expect(Wavebird::ConfigurationError.superclass).to eq(described_class)
    end
  end

  describe Wavebird::RateLimitedError do
    it "exposes retry_after alongside the envelope" do
      error = described_class.new("slow down", retry_after: 12, code: "rate_limited", http_status: 429,
                                               request_id: "req_429")

      expect(error.retry_after).to eq(12)
      expect(error.code).to eq("rate_limited")
      expect(error.http_status).to eq(429)
      expect(error.request_id).to eq("req_429")
    end

    it "defaults retry_after to nil" do
      expect(described_class.new("slow down").retry_after).to be_nil
    end
  end
end
