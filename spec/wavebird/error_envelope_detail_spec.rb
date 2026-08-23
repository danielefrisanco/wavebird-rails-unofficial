# frozen_string_literal: true

# wavebird's error envelope carries more than `message`, and the extra fields are
# usually the only actionable part. A real 400 during the 2026-08-23 sandbox
# investigation said, in full:
#
#   "Request validation failed. Check the request body schema, required fields,
#    and value ranges before retrying."
#
# ...while the same response also carried
# `reason_code: "e01_request_authority_malformed_bidfloor"`, which named the
# cause exactly. The gem discarded it, and finding it by hand took a dozen
# probes against the live API. None of these fields are in wavebird's documented
# envelope; they were found empirically, so this spec is also the record that
# they exist.
RSpec.describe Wavebird::Error, "API envelope diagnostics" do
  include_context "with a configured client"

  let(:placements_url) { "#{api_base}/v1/placements" }

  # The real body, trimmed. Keeping it verbatim matters: it is evidence of the
  # shape, not an invention of ours.
  let(:envelope) do
    {
      "error" => "validation_error",
      "message" => "Invalid placement request.",
      "request_id" => "e06adeb2-3c02-47a4-869f-dbcf560dfb58",
      "docs_url" => "/api/reference/errors#validation_error",
      "reason_code" => "e01_request_authority_malformed_bidfloor",
      "hint" => "Use the flat Server API request body: client_id, session_id, job_type, " \
                "locale, slots_requested, prompt, slot_hint, overrides, and consent at the top level.",
      "expected_shape" => "flat_server_api_v1",
      "fields" => [
        { "path" => "overrides.bidfloor", "message" => "Expected a non-negative number.",
          "expected" => "number >= 0" }
      ]
    }
  end

  def raise_with(body)
    stub_request(:post, placements_url).with(query: hash_including({}))
                                       .to_return(status: 400, body: JSON.generate(body))
    client.create_placement(job_type: "chat")
  rescue Wavebird::Error => e
    e
  end

  it "keeps every diagnostic field the API sent" do
    error = raise_with(envelope)

    expect(error).to be_a(Wavebird::ValidationError)
    expect(error.reason_code).to eq("e01_request_authority_malformed_bidfloor")
    expect(error.expected_shape).to eq("flat_server_api_v1")
    expect(error.hint).to start_with("Use the flat Server API request body")
    expect(error.fields).to eq([{ "path" => "overrides.bidfloor",
                                  "message" => "Expected a non-negative number.",
                                  "expected" => "number >= 0" }])
  end

  it "still carries the documented fields" do
    error = raise_with(envelope)

    expect(error.code).to eq("validation_error")
    expect(error.request_id).to eq("e06adeb2-3c02-47a4-869f-dbcf560dfb58")
    expect(error.http_status).to eq(400)
    expect(error.message).to eq("Invalid placement request.")
  end

  describe "#diagnostic_message" do
    it "puts the actionable fields next to the generic message" do
      described = raise_with(envelope).diagnostic_message

      expect(described).to include("Invalid placement request.")
      expect(described).to include("reason_code=e01_request_authority_malformed_bidfloor")
      expect(described).to include("expected_shape=flat_server_api_v1")
      expect(described).to include("field overrides.bidfloor: Expected a non-negative number.")
    end

    it "is just the message when the API sent no diagnostics" do
      error = raise_with("error" => "unauthorized", "message" => "Invalid API key.")

      expect(error.diagnostic_message).to eq("Invalid API key.")
    end

    it "skips a field entry carrying nothing useful" do
      error = raise_with(envelope.merge("fields" => [{}]))

      expect(error.diagnostic_message).not_to include("field ")
    end

    # Tolerant reads again: an entry that is not hash-like must not blow up the
    # reporter, which runs on the failure path where nothing else can help.
    it "skips a field entry that is not hash-like" do
      error = raise_with(envelope.merge("fields" => ["overrides.bidfloor", nil]))

      expect { error.diagnostic_message }.not_to raise_error
      expect(error.diagnostic_message).not_to include("field ")
    end
  end

  it "ignores a fields value that is not an array" do
    # Tolerant reads, as everywhere else in the gem: an unexpected shape must
    # not turn a reportable API error into a NoMethodError inside the reporter.
    error = raise_with(envelope.merge("fields" => "overrides.bidfloor"))

    expect(error.fields).to be_nil
    expect { error.diagnostic_message }.not_to raise_error
  end

  # Ruby 3.2+ defines Exception#detailed_message(highlight:) and calls it while
  # printing an uncaught exception. An earlier version of this feature named the
  # method that, with zero arity, so a Wavebird::Error escaping to the top level
  # raised ArgumentError *inside Ruby's error rendering* -- replacing the real
  # failure with a confusing one. Pinned so the name is never reclaimed.
  it "leaves Ruby's own detailed_message intact" do
    error = raise_with(envelope)

    expect { error.detailed_message(highlight: false) }.not_to raise_error
    expect(error.detailed_message(highlight: false)).to include("Invalid placement request.")
  end

  # A non-wavebird exception reaches the same reporter when a `before_send_text`
  # hook raises (#028), and it has no diagnostics to add.
  it "reports a plain exception through the same path without diagnostics" do
    logger = instance_double(Logger, warn: nil)
    config.logger = logger
    config.before_send_text = ->(_text) { raise "scrubber exploded" }
    stub_request(:post, placements_url).with(query: hash_including({}))
                                       .to_return(status: 200, body: JSON.generate("status" => "no_fill",
                                                                                   "placement" => nil))

    client.create_placement(job_type: "chat", topic: "cloud hosting")

    expect(logger).to have_received(:warn).with(/scrubber exploded/)
  end

  it "reaches the host through on_error, which is where a human reads it" do
    errors = []
    logger = instance_double(Logger, warn: nil)
    config.on_error = ->(e) { errors << e }
    config.logger = logger
    stub_request(:post, placements_url).with(query: hash_including({}))
                                       .to_return(status: 400, body: JSON.generate(envelope))

    Wavebird::Facade.new(config: config).create_placement(job_type: "chat")

    expect(errors.first.reason_code).to eq("e01_request_authority_malformed_bidfloor")
    expect(logger).to have_received(:warn).with(/reason_code=e01_request_authority_malformed_bidfloor/)
  end
end
