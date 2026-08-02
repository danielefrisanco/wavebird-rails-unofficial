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

  # The bug this exists to prevent: the Turbo Stream used to be named for the slot
  # position alone, so every visitor at that position shared one channel. One
  # visitor's decision — including the frame_url that embeds their asset_token —
  # was broadcast to all of them, rendering their ad in strangers' pages and
  # firing their beacons from unrelated browsers.
  #
  # Single-session specs cannot see this: the leak only appears with a second
  # concurrent visitor, which is why it survived Phase 8.
  describe "with two concurrent visitors" do
    # rubocop:disable RSpec/ExampleLength -- two browser sessions have to be
    # driven in one example: the leak only exists *between* them, and splitting
    # would pay for a second browser boot to assert half of one scenario.
    it "delivers a decision only to the visitor it belongs to", :aggregate_failures do
      stub_job
      stub_request(:get, %r{/v1/decisions/slot_1})
        .to_return(status: 200, body: JSON.generate(ready_fill_decision),
                   headers: { "Content-Type" => "application/json" })

      # Two Capybara sessions = two cookie jars = two wavebird_session_ids, so
      # each subscribes to its own stream.
      visitor_b_stream = nil
      Capybara.using_session(:visitor_b) do
        visit "/chat/async"
        wait_for_dummy_ready
        wait_for_stream_subscription
        visitor_b_stream = stream_source_names
      end

      visit "/chat/async"
      wait_for_dummy_ready
      wait_for_stream_subscription
      visitor_a_stream = stream_source_names

      # Precondition: the two visitors really are on different streams.
      expect(visitor_a_stream).not_to be_empty
      expect(visitor_a_stream).not_to eq(visitor_b_stream)

      # Visitor A takes a turn; only A's decision is broadcast.
      click_button(id: "send-path-a")
      expect(page).to have_text("AI answered")
      run_poll_job

      expect(page).to have_css("#wavebird-slot-below[data-wavebird-status='rendered']")

      Capybara.using_session(:visitor_b) do
        # B never took a turn, so B's slot must stay hidden and empty — no frame,
        # and no trace of A's asset token anywhere in B's page.
        expect(page).to have_no_css("iframe[data-wavebird-frame]", visible: :all)
        expect(slot).not_to be_visible
        expect(page.evaluate_script("document.body.innerHTML")).not_to include("at_secret_async")
      end
    end
    # rubocop:enable RSpec/ExampleLength
  end

  # The signed stream names the page is subscribed to. Two visitors on the same
  # position must not share one.
  def stream_source_names
    page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll("turbo-cable-stream-source"))
           .map((el) => el.getAttribute("signed-stream-name"))
    JS
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
