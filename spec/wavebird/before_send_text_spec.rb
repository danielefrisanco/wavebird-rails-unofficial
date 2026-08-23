# frozen_string_literal: true

# `config.before_send_text` is the redaction seam: a host filters caller-supplied
# free text on its way to wavebird without monkey-patching anything. It is the
# only way to filter the **engine endpoint**, where the caller is
# `SponsorSlotsController` inside this gem and the host has no call site of their
# own to redact at.
#
# Every example here asserts against the **wire body** rather than a return
# value. A hook that transforms a value the request does not actually carry is
# the failure this spec exists to make impossible.
RSpec.describe Wavebird::Client, "config.before_send_text" do
  include_context "with a configured client"

  let(:placements_url) { "#{api_base}/v1/placements" }
  let(:jobs_url) { "#{api_base}/v1/jobs" }
  let(:no_fill) { { "slot_id" => "slot_1", "status" => "no_fill", "placement" => nil, "decision" => nil } }
  let(:accepted) { { "job_id" => "job_1", "slot_ids" => ["slot_1"], "status" => "accepted" } }

  # The body wavebird actually received, for the one assertion that matters.
  def captured_body(stub)
    body = nil
    stub.to_return do |request|
      body = JSON.parse(request.body)
      { status: 200, body: JSON.generate(no_fill) }
    end
    -> { body }
  end

  describe "when unset (the default)" do
    it "sends the topic through untouched" do
      stub = stub_request(:post, placements_url).with(query: hash_including({}))
      read_body = captured_body(stub)

      client.create_placement(job_type: "chat", topic: "cloud hosting")

      expect(read_body.call["prompt"]).to eq("topic" => "cloud hosting")
    end

    it "is nil, so a host that ignores it has no branch to opt out of" do
      expect(config.before_send_text).to be_nil
    end
  end

  describe "when set" do
    it "sends the replacement, not the original — on create_placement" do
      config.before_send_text = ->(text) { text.gsub(/\d/, "#") }
      stub = stub_request(:post, placements_url).with(query: hash_including({}))
      read_body = captured_body(stub)

      client.create_placement(job_type: "chat", topic: "call me on 5551234")

      expect(read_body.call["prompt"]).to eq("topic" => "call me on #######")
    end

    # Both endpoint methods build `prompt` the same way, so both must filter it.
    # Fixing this in the client rather than at one call site is what keeps the
    # two routes symmetric -- the same reasoning as #020's merged-overrides check.
    it "sends the replacement, not the original — on create_job" do
      config.before_send_text = ->(text) { "REDACTED(#{text.length})" }
      body = nil
      stub_request(:post, jobs_url)
        .with(query: hash_including({}))
        .to_return do |request|
        body = JSON.parse(request.body)
        { status: 200, body: JSON.generate(accepted) }
      end

      client.create_job(job_type: "chat", topic: "secret plans")

      expect(body["prompt"]).to eq("topic" => "REDACTED(12)")
    end

    it "is never handed credentials, client_id, or any structural field" do
      seen = []
      config.before_send_text = ->(text) { seen << text }
      stub_request(:post, placements_url).with(query: hash_including({}))
                                         .to_return(status: 200, body: JSON.generate(no_fill))

      client.create_placement(job_type: "chat", session_id: "sess_1", locale: "en-US",
                              topic: "cloud hosting", consent: { semantic_targeting: false })

      # One call, one value: the free text. Not the secret key, not wbproj_spec,
      # not the consent object. The hook cannot rewrite what it is never shown.
      expect(seen).to eq(["cloud hosting"])
    end

    it "drops the field when the hook returns nil" do
      # An empty lambda returns nil; RuboCop's Style/NilLambda rejects the
      # explicit `{ nil }` this example is actually about.
      config.before_send_text = ->(_text) {}
      stub = stub_request(:post, placements_url).with(query: hash_including({}))
      read_body = captured_body(stub)

      client.create_placement(job_type: "chat", topic: "cloud hosting")

      expect(read_body.call).not_to have_key("prompt")
    end

    it "is not called at all when there is no topic to filter" do
      called = false
      config.before_send_text = lambda { |text|
        called = true
        text
      }
      stub_request(:post, placements_url).with(query: hash_including({}))
                                         .to_return(status: 200, body: JSON.generate(no_fill))

      client.create_placement(job_type: "chat")

      expect(called).to be(false)
    end
  end

  # The decision Daniele made on 2026-08-11: "send the original or drop the
  # field" -> "I'd say drop". A broken filter must never leak the value it was
  # installed to catch, so this fails closed. The cost is real and is why the
  # failure is reported loudly rather than swallowed quietly.
  describe "when the hook raises" do
    let(:boom) { ->(_text) { raise "scrubber exploded" } }

    it "drops the field rather than sending the unfiltered original" do
      config.before_send_text = boom
      stub = stub_request(:post, placements_url).with(query: hash_including({}))
      read_body = captured_body(stub)

      client.create_placement(job_type: "chat", topic: "cloud hosting")

      body = read_body.call
      expect(body).not_to have_key("prompt")
      expect(JSON.generate(body)).not_to include("cloud hosting")
    end

    it "does not take down the request" do
      config.before_send_text = boom
      stub_request(:post, placements_url).with(query: hash_including({}))
                                         .to_return(status: 200, body: JSON.generate(no_fill))

      expect { client.create_placement(job_type: "chat", topic: "cloud hosting") }.not_to raise_error
    end

    it "reports through on_error and logs at warn, every time and not once" do
      errors = []
      logger = instance_double(Logger)
      allow(logger).to receive(:warn)
      config.on_error = ->(e) { errors << e }
      config.logger = logger
      config.before_send_text = boom
      stub_request(:post, placements_url).with(query: hash_including({}))
                                         .to_return(status: 200, body: JSON.generate(no_fill))

      2.times { client.create_placement(job_type: "chat", topic: "cloud hosting") }

      # Twice, not once: a persistently broken filter silently degrades every
      # auction -- topic vanishes, fills get worse, nothing errors -- so the
      # noise is the mitigation.
      expect(errors.length).to eq(2)
      expect(errors.first.message).to eq("scrubber exploded")
      expect(logger).to have_received(:warn).twice.with(/scrubber exploded/)
    end

    it "survives an on_error observer that also raises" do
      config.on_error = ->(_e) { raise "observer exploded" }
      config.before_send_text = boom
      stub_request(:post, placements_url).with(query: hash_including({}))
                                         .to_return(status: 200, body: JSON.generate(no_fill))

      expect { client.create_placement(job_type: "chat", topic: "cloud hosting") }.not_to raise_error
    end
  end
end
