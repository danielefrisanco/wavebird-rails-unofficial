# frozen_string_literal: true

require_relative "../support/system_tests"

# Phase 6a in a real browser: the Stimulus controller, the hosted-renderer glue
# and both host entry points from decision #008, driven through headless Chrome
# against the dummy host app.
RSpec.describe "Sponsor slot — blocking delivery", type: :system do
  # Both documented ways for a host to hand its chat turn to wavebird. The
  # scenarios below are identical for each, which is the point: whichever entry
  # point a host picks, the slot behaves the same.
  {
    "path A (wavebird:turn event)" => "#send-path-a",
    "path C (window.wavebird.withTurn)" => "#send-path-c"
  }.each do |label, button|
    context "when the host uses #{label}" do
      it "reveals the slot and renders the hosted frame on a fill" do
        stub_placement(fill_body)

        visit "/chat"
        wait_for_dummy_ready
        click_button(id: button.delete_prefix("#"))

        expect(page).to have_css("#wavebird-slot-below[data-wavebird-status='rendered']")
        expect(slot).not_to be_nil
        expect(page).to have_css("iframe[data-wavebird-frame]", visible: :all)
      end

      it "still delivers the AI answer on a fill" do
        stub_placement(fill_body)

        visit "/chat"
        wait_for_dummy_ready
        click_button(id: button.delete_prefix("#"))

        expect(page).to have_text("AI answered")
      end

      it "keeps the slot hidden on a no-fill and lets the chat flow proceed" do
        stub_placement(no_fill_body)

        visit "/chat"
        wait_for_dummy_ready
        click_button(id: button.delete_prefix("#"))

        expect(page).to have_text("AI answered")
        expect(page).to have_no_css("iframe[data-wavebird-frame]", visible: :all)
        expect(slot).not_to be_visible
      end

      it "leaves the chat flow unaffected when the wavebird API is down" do
        stub_request(:post, "#{api_base_url}/v1/placements")
          .with(query: hash_including({}))
          .to_return(status: 500, body: JSON.generate("error" => "boom"))

        visit "/chat"
        wait_for_dummy_ready
        click_button(id: button.delete_prefix("#"))

        expect(page).to have_text("AI answered")
        expect(page).to have_no_css("iframe[data-wavebird-frame]", visible: :all)
      end

      it "runs the chat turn even when the hosted renderer never loads" do
        stub_placement(fill_body)

        # ?no_renderer=1 omits the render.js script tag, so window.wavebird is
        # absent — the host's turn must still complete (§4).
        visit "/chat?no_renderer=1"
        wait_for_dummy_ready
        click_button(id: button.delete_prefix("#"))

        expect(page).to have_text("AI answered")
        expect(page).to have_no_css("iframe[data-wavebird-frame]", visible: :all)
      end
    end
  end

  describe "the request the browser makes" do
    it "carries the stable session id on path A" do
      stub_placement(fill_body)

      visit "/chat"
      wait_for_dummy_ready
      session_id = slot["data-wavebird-session-id-value"]
      click_button(id: "send-path-a")
      expect(page).to have_css("#wavebird-slot-below[data-wavebird-status='rendered']")

      # The helper renders the session id as a Stimulus value; the controller
      # injects it into the POST body, which the engine forwards upstream
      # (render.js's own default body would carry a random uuid — decision #008).
      expect(session_id).to start_with("sess_")
      expect(
        a_request(:post, "#{api_base_url}/v1/placements")
          .with(query: hash_including({}), body: hash_including("session_id" => session_id))
      ).to have_been_made
    end

    it "never exposes the secret key to the browser" do
      stub_placement(fill_body)

      visit "/chat"
      wait_for_dummy_ready
      click_button(id: "send-path-a")
      expect(page).to have_css("#wavebird-slot-below[data-wavebird-status='rendered']")

      expect(page.html).not_to include("sk_test")
    end
  end
end
