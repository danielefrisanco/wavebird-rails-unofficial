# frozen_string_literal: true

RSpec.describe Wavebird::Client, "deprecated timing" do
  include_context "with a configured client"

  let(:logger) { instance_spy(Logger) }
  let(:jobs_url) { "#{api_base}/v1/jobs" }
  let(:placements_url) { "#{api_base}/v1/placements" }
  let(:timing_warning) { /Using 'before' timing.*recommended timing is 'during'/ }

  before do
    config.logger = logger
    stub_request(:post, jobs_url).to_return(status: 200, body: JSON.generate(
      "job_id" => "job_1", "slot_ids" => %w[slot_1], "status" => "accepted"
    ))
    stub_request(:post, placements_url).with(query: hash_including({}))
                                       .to_return(status: 200, body: JSON.generate(
                                         "slot_id" => "slot_1", "status" => "ready",
                                         "placement" => nil, "decision" => nil
                                       ))
  end

  after { Wavebird::Deprecation.reset! }

  it "warns when a call passes the legacy timing" do
    client.create_placement(job_type: "chat", overrides: { timing: "before" })

    expect(logger).to have_received(:warn).with(timing_warning)
  end

  it "warns for the other legacy value" do
    client.create_placement(job_type: "chat", overrides: { timing: "after" })

    expect(logger).to have_received(:warn).with(/Using 'after' timing/)
  end

  # A timing set once in an initializer is the likeliest way to acquire this
  # silently, so the check runs on the merged overrides, not the argument.
  it "warns when the timing comes from config.default_overrides" do
    config.default_overrides = { timing: "before" }

    client.create_job(job_type: "chat")

    expect(logger).to have_received(:warn).with(timing_warning)
  end

  it "warns once per process however many jobs are created" do
    3.times { client.create_placement(job_type: "chat", overrides: { timing: "before" }) }

    expect(logger).to have_received(:warn).with(timing_warning).once
  end

  it "says nothing for the recommended timing" do
    client.create_placement(job_type: "chat", overrides: { timing: "during" })

    expect(logger).not_to have_received(:warn)
  end

  it "says nothing when no timing is set" do
    client.create_placement(job_type: "chat")

    expect(logger).not_to have_received(:warn)
  end

  it "still sends the value it warned about — wavebird decides what it means" do
    stub = stub_request(:post, placements_url)
           .with(query: hash_including({}), body: hash_including("overrides" => { "timing" => "before" }))
           .to_return(status: 200, body: JSON.generate("slot_id" => "s", "status" => "ready",
                                                       "placement" => nil, "decision" => nil))

    client.create_placement(job_type: "chat", overrides: { timing: "before" })

    expect(stub).to have_been_requested
  end
end
