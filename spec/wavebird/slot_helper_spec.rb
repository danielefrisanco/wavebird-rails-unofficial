# frozen_string_literal: true

RSpec.describe Wavebird::SlotHelper do
  # A minimal view context that mixes in the helper, so its output is exercised
  # through the real ActionView tag builders.
  let(:view) do
    ActionView::Base
      .with_empty_template_cache
      .new(ActionView::LookupContext.new([]), {}, nil)
      .tap { |v| v.extend(described_class) }
  end

  after { Wavebird.reset_configuration! }

  describe "#wavebird_render_script_tag" do
    it "emits a script tag pointing at the configured render.js" do
      html = view.wavebird_render_script_tag

      expect(html).to include(%(src="https://api.wavebird.ai/v1/render.js"))
      expect(html).to include("async")
      expect(html).to include("<script")
    end

    it "points at a custom api_base_url" do
      Wavebird.configure { |c| c.api_base_url = "https://sandbox.wavebird.ai" }

      expect(view.wavebird_render_script_tag).to include("https://sandbox.wavebird.ai/v1/render.js")
    end

    it "emits the tag only once per page even when called repeatedly" do
      first = view.wavebird_render_script_tag
      second = view.wavebird_render_script_tag

      expect(first).to include("<script")
      expect(second).to be_nil
    end
  end

  describe "#wavebird_slot" do
    subject(:html) { view.wavebird_slot(endpoint: "/wavebird/sponsor_slot", session_id: "sess_1") }

    it "renders a section starting hidden" do
      expect(html).to match(/<section[^>]*hidden/)
    end

    it "carries the endpoint and Stimulus controller for the browser glue" do
      expect(html).to include(%(data-controller="wavebird"))
      expect(html).to include(%(data-wavebird-endpoint="/wavebird/sponsor_slot"))
    end

    it "passes the session id and position as Stimulus values" do
      expect(html).to include(%(data-wavebird-session-id-value="sess_1"))
      expect(html).to include(%(data-wavebird-position-value="below"))
    end

    it "builds the id from the position" do
      expect(view.wavebird_slot(endpoint: "/e", position: "sidebar")).to include(%(id="wavebird-slot-sidebar"))
    end

    it "omits the session-id value when none is given" do
      expect(view.wavebird_slot(endpoint: "/e")).not_to include("data-wavebird-session-id-value")
    end

    it "merges extra html options onto the section" do
      expect(view.wavebird_slot(endpoint: "/e", class: "ad-slot")).to include(%(class="ad-slot"))
    end

    it "emits no Turbo Stream subscription in the default (blocking) mode" do
      expect(html).not_to include("turbo-cable-stream-source")
    end
  end

  describe "#wavebird_slot in async mode" do
    it "subscribes the slot to its Turbo Stream when turbo_stream_from is available" do
      # Give the view a turbo_stream_from, mimicking turbo-rails being loaded.
      view.define_singleton_method(:turbo_stream_from) do |stream|
        %(<turbo-cable-stream-source signed-stream-name="#{stream}"></turbo-cable-stream-source>).html_safe
      end

      html = view.wavebird_slot(endpoint: "/e", position: "below", async: true)

      expect(html).to include(%(signed-stream-name="wavebird_slot_below"))
      expect(html).to include(%(id="wavebird-slot-below")) # the section is still rendered
    end

    it "renders just the section (no crash) when turbo_stream_from is unavailable" do
      html = view.wavebird_slot(endpoint: "/e", position: "below", async: true)

      expect(html).to include(%(id="wavebird-slot-below"))
      expect(html).not_to include("turbo-cable-stream-source")
    end
  end
end
