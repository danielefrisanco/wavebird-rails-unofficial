# frozen_string_literal: true

# Placeholder credentials for mocked-HTTP client specs (no real secrets;
# WebMock blocks all network access — see WAY_OF_WORK.md).
RSpec.shared_context "with a configured client" do
  let(:config) do
    Wavebird::Configuration.new.tap do |c|
      c.secret_key = "sk_test_spec_placeholder"
      c.client_id = "wbproj_spec"
    end
  end

  let(:client) { Wavebird::Client.new(config: config) }
  let(:api_base) { "https://api.wavebird.ai" }
end
