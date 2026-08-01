# frozen_string_literal: true

require_relative "../support/system_tests"

# Phase 6b in a real browser: async delivery mode end to end — the endpoint
# answers immediately, the poll job resolves the decision server-side, and the
# slot is revealed (or left hidden) by a genuine Turbo Stream broadcast over
# ActionCable. Nothing here is simulated: real cable, real broadcast, real
# Stimulus target callback, real hosted-renderer entry point.
RSpec.describe "Sponsor slot — async delivery", type: :system do
  # The browser must be subscribed before the job broadcasts, otherwise the
  # message is delivered to nobody and the test races.
  def wait_for_stream_subscription
    expect(page).to have_css("turbo-cable-stream-source[connected]", visible: :all)
  end

  # Runs the enqueued DecisionPollJob the way a queue worker would.
  def run_poll_job
    perform_enqueued_jobs
  end

  # `src` of the iframe the hosted renderer mounted, or nil if none.
  def rendered_frame_src
    page.evaluate_script(<<~JS)
      (() => {
        const frame = document.querySelector("iframe[data-wavebird-frame]");
        return frame ? frame.src : null;
      })()
    JS
  end

  # Everything the browser actually received inside the page body — the place a
  # leaked token or key would show up.
  def slot_dom
    page.evaluate_script("document.body.innerHTML")
  end

  # Drives a full async turn: load the page, take the turn, run the poll job, and
  # wait for the broadcast to reveal the slot.
  def take_a_turn_and_reveal
    visit "/chat/async"
    wait_for_dummy_ready
    wait_for_stream_subscription
    click_button(id: "send-path-a")
    expect(page).to have_text("AI answered")
    run_poll_job
    expect(page).to have_css("#wavebird-slot-below[data-wavebird-status='rendered']")
  end

  it "answers the browser immediately without waiting for a decision" do
    stub_job
    stub_request(:get, %r{/v1/decisions/slot_1})
      .to_return(status: 200, body: JSON.generate(ready_fill_decision),
                 headers: { "Content-Type" => "application/json" })

    visit "/chat/async"
    wait_for_dummy_ready
    wait_for_stream_subscription
    click_button(id: "send-path-a")

    # The chat turn completes on the pending response; the slot is still hidden.
    expect(page).to have_text("AI answered")
    expect(page).to have_no_css("iframe[data-wavebird-frame]", visible: :all)
  end

  it "reveals the slot when the poll job broadcasts a fill" do
    stub_job
    stub_request(:get, %r{/v1/decisions/slot_1})
      .to_return(status: 200, body: JSON.generate(ready_fill_decision),
                 headers: { "Content-Type" => "application/json" })

    visit "/chat/async"
    wait_for_dummy_ready
    wait_for_stream_subscription
    click_button(id: "send-path-a")
    expect(page).to have_text("AI answered")

    run_poll_job

    # The broadcast lands over the cable, the Stimulus signal target connects,
    # and the hosted renderer mounts the frame.
    expect(page).to have_css("#wavebird-slot-below[data-wavebird-status='rendered']")
    expect(page).to have_css("iframe[data-wavebird-frame]", visible: :all)
  end

  it "keeps the slot hidden when the poll job broadcasts a no-fill" do
    stub_job
    stub_request(:get, %r{/v1/decisions/slot_1})
      .to_return(status: 200, body: JSON.generate(ready_no_fill_decision),
                 headers: { "Content-Type" => "application/json" })

    visit "/chat/async"
    wait_for_dummy_ready
    wait_for_stream_subscription
    click_button(id: "send-path-a")
    expect(page).to have_text("AI answered")

    run_poll_job

    expect(page).to have_no_css("iframe[data-wavebird-frame]", visible: :all)
    expect(slot).not_to be_visible
  end

  it "leaves the chat flow untouched when the decision poll fails" do
    stub_job
    stub_request(:get, %r{/v1/decisions/slot_1})
      .to_return(status: 500, body: JSON.generate("error" => "boom"))

    visit "/chat/async"
    wait_for_dummy_ready
    wait_for_stream_subscription
    click_button(id: "send-path-a")
    expect(page).to have_text("AI answered")

    # The facade swallows the error into a no-fill, so the job still broadcasts
    # a hide rather than raising into the queue.
    expect { run_poll_job }.not_to raise_error
    expect(page).to have_no_css("iframe[data-wavebird-frame]", visible: :all)
  end

  it "sends no bare asset token and no secret key to the browser", :aggregate_failures do
    stub_job
    stub_request(:get, %r{/v1/decisions/slot_1})
      .to_return(status: 200, body: JSON.generate(ready_fill_decision),
                 headers: { "Content-Type" => "application/json" })

    take_a_turn_and_reveal

    # The server folds the token into frame_url (decision #009) — that one
    # embedding is by design, since the hosted renderer authenticates the frame
    # with it. What must never appear is the token as a value of its own, or the
    # secret key in any form. Same boundary the blocking path asserts.
    expect(rendered_frame_src).to eq("#{api_base_url}/v1/render/at_secret_async")
    expect(slot_dom).not_to include("asset_token")
    expect(slot_dom.scan("at_secret_async").size).to eq(1) # the iframe src only
    expect(page.html).not_to include("sk_test")
  end

  # A ready fill decision as returned by GET /v1/decisions/{slot_id}: it carries
  # the raw asset_token and a creative, not a resolved frame_url.
  def ready_fill_decision
    {
      "slot_id" => "slot_1", "status" => "ready",
      "decision" => {
        "fill" => true, "format" => "banner", "asset_token" => "at_secret_async",
        "cs_declaration" => "sponsored", "constraints" => {},
        "delivery_url" => "https://cdn.example/creative.png",
        "dimensions" => { "width" => 728, "height" => 90 },
        "sponsor_name" => "Acme"
      }
    }
  end

  def ready_no_fill_decision
    {
      "slot_id" => "slot_1", "status" => "ready",
      "decision" => {
        "fill" => false, "reason" => "no_demand",
        "no_fill_reason" => "no_demand", "cs_declaration" => "none"
      }
    }
  end
end
