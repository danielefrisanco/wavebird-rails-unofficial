# frozen_string_literal: true

require "wavebird/decision_poll_job"

RSpec.describe Wavebird::DecisionPollJob do
  let(:facade) { instance_double(Wavebird::Facade) }
  let(:stream) { "wavebird_slot_below_sess_1" }
  # A stand-in Turbo::StreamsChannel that records the broadcast arguments, so the
  # test does not need turbo-rails/ActionCable wired.
  let(:channel) { spy("Turbo::StreamsChannel") } # rubocop:disable RSpec/VerifiedDoubles

  before do
    allow(Wavebird).to receive(:client).and_return(facade)
    Wavebird.configure { |c| c.api_base_url = "https://api.wavebird.ai" }
    stub_const("Turbo::StreamsChannel", channel)
  end

  after { Wavebird.reset_configuration! }

  def perform(decision)
    allow(facade).to receive(:await_decision).with("slot_1").and_return(decision)
    described_class.new.perform("slot_1", stream, "below")
  end

  it "polls the slot through the fail-silent facade" do
    perform(Wavebird::Types::Decision.from_api("slot_id" => "slot_1", "status" => "ready", "fill" => false))

    expect(facade).to have_received(:await_decision).with("slot_1")
  end

  context "when the decision is a fill" do
    let(:decision) do
      Wavebird::Types::Decision.from_api(
        "slot_id" => "slot_1", "status" => "ready", "fill" => true,
        "asset_token" => "at_secret_proof",
        "creative" => { "width" => 300, "height" => 250, "sponsor_name" => "Acme" }
      )
    end

    it "broadcasts a reveal to the slot's stream with the browser-safe payload" do
      perform(decision)

      expect(channel).to have_received(:broadcast_append_to).with(
        stream,
        hash_including(target: "wavebird-slot-below", partial: "wavebird/slot_broadcast",
                       locals: hash_including(payload: hash_including(fill: true)))
      )
    end

    it "never puts the bare asset_token in the broadcast payload" do
      perform(decision)

      payload = nil
      expect(channel).to have_received(:broadcast_append_to) do |_stream, opts|
        payload = opts[:locals][:payload]
      end
      expect(payload).not_to have_key(:asset_token)
      expect(payload.dig(:placement, :render, :frame_url))
        .to eq("https://api.wavebird.ai/v1/render/at_secret_proof")
      expect(payload.to_json).not_to include('"asset_token"')
    end
  end

  context "when the decision is a no-fill" do
    it "broadcasts a hide payload" do
      perform(Wavebird::Types::Decision.from_api("slot_id" => "slot_1", "status" => "ready", "fill" => false))

      expect(channel).to have_received(:broadcast_append_to).with(
        stream, hash_including(locals: hash_including(payload: { fill: false }))
      )
    end
  end

  context "when Turbo Streams is not available" do
    it "does not raise (broadcast is a guarded no-op)" do
      hide_const("Turbo::StreamsChannel")
      allow(facade).to receive(:await_decision).and_return(
        Wavebird::Types::Decision.from_api("slot_id" => "slot_1", "status" => "ready", "fill" => false)
      )

      expect { described_class.new.perform("slot_1", stream, "below") }.not_to raise_error
    end
  end

  it "targets the slot section for the position it was given" do
    # The broadcast must land inside the controller's element for Stimulus to see
    # the signal target. Position is passed explicitly rather than parsed back out
    # of the stream name, which is now session-scoped and no longer decomposable.
    allow(facade).to receive(:await_decision).and_return(
      Wavebird::Types::Decision.from_api("slot_id" => "slot_1", "status" => "ready", "fill" => false)
    )

    described_class.new.perform("slot_1", "wavebird_slot_sidebar_sess_9", "sidebar")

    expect(channel).to have_received(:broadcast_append_to)
      .with("wavebird_slot_sidebar_sess_9", hash_including(target: "wavebird-slot-sidebar"))
  end

  # The whole point of the session scoping: two visitors at the same position get
  # different streams, so one visitor's decision cannot land in the other's page.
  it "broadcasts onto the session-scoped stream it was given, not a shared one" do
    allow(facade).to receive(:await_decision).and_return(
      Wavebird::Types::Decision.from_api("slot_id" => "slot_1", "status" => "ready", "fill" => false)
    )

    described_class.new.perform("slot_1", "wavebird_slot_below_sess_a", "below")

    expect(channel).to have_received(:broadcast_append_to).with("wavebird_slot_below_sess_a", anything)
    expect(channel).not_to have_received(:broadcast_append_to).with("wavebird_slot_below", anything)
  end

  it "reads the configured async queue name" do
    Wavebird.configure { |c| c.async_queue_name = :wavebird_low }

    expect(described_class.new.queue_name).to eq("wavebird_low")
  end
end
