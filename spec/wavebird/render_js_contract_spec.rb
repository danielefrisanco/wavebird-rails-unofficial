# frozen_string_literal: true

require "json"
require "open3"

# The system specs drive a local stand-in for wavebird's hosted render.js
# (spec/dummy/public/v1/render.js), because the real script cannot be fetched
# with net connections disabled. That stand-in is only trustworthy while it
# matches the real contract, so this spec pins both sides against the snapshot in
# docs/upstream/.
#
# The contract has two halves, and for a while this spec only checked one:
#
#   1. **entry points** — the functions the gem calls still exist upstream and
#      are still stubbed locally;
#   2. **payload shape** — the JSON the gem's endpoint returns still resolves to
#      a render inside those functions.
#
# Only checking (1) is what let a broken payload ship: every entry point existed,
# every system spec passed, and the real renderer painted nothing because the
# gem's flat `{fill:true, frame_url:…}` satisfied no branch of `renderFrom`. The
# renderer has no error path for an unresolvable payload — it just clears the
# slot — so the failure was completely silent. See decision #017.
#
# Nothing in this file boots Rails or a browser; it reads the snapshot and, where
# node is available, executes the snapshot's own resolution functions against the
# gem's real payload.

# Whether the node-executed proof below can run. Its absence does not weaken the
# gate: the shape assertions that always run pin the same path in pure Ruby.
WAVEBIRD_NODE_AVAILABLE = begin
  Open3.capture2("node", "--version")[1].success?
rescue Errno::ENOENT, Errno::EACCES
  false
end

# The exact upstream source that decides whether an endpoint response paints
# anything. The gem's payload is shaped to satisfy precisely these lines, so a
# snapshot refresh that changes them must fail here rather than leave the gem
# emitting a shape the renderer silently ignores.
WAVEBIRD_RESOLUTION_PATH = {
  "placementFrom unwraps response.placement, or options.decision.placement" =>
    "var p=input&&input.placement?input.placement:input&&input.decision&&" \
    "input.decision.placement?input.decision.placement:input",
  "renderFrom resolves a render from p.render.frame_url" =>
    "var r=p&&p.render;if(r&&r.frame_url)return r",
  "startTurn discards a response that carries no placement.render" =>
    "var p=placementFrom({decision:decision});if(!p||!p.render)",
  "startTurn hands the whole endpoint response to renderPlacement" =>
    "api.renderPlacement({target:target,decision:decision})",
  "renderPlacement re-resolves from its own options" =>
    "var p=placementFrom(options);var r=renderFrom(p)"
}.freeze

RSpec.describe "hosted render.js contract", :aggregate_failures do # rubocop:disable RSpec/DescribeClass
  # The surface the gem actually drives: the Stimulus controller calls withTurn
  # (both host entry points, decision #008) and renderPlacement/clearPlacement
  # for the async reveal (decision #009). startTurn is withTurn's own primitive.
  let(:required_entry_points) { %w[withTurn startTurn renderPlacement clearPlacement] }
  let(:frame_url) { "https://api.wavebird.ai/v1/render/at_secret" }

  # Plain methods rather than `let`s: they are paths and file reads, not per-example
  # fixtures, and the payload group below is already at RuboCop's memoized-helper cap.
  def snapshot_path
    Dir.glob(File.expand_path("../../docs/upstream/render-js-snapshot-*.js", __dir__)).max
  end

  def snapshot
    File.read(snapshot_path)
  end

  def stand_in_path
    File.expand_path("../dummy/public/v1/render.js", __dir__)
  end

  it "has a dated upstream snapshot to check against" do
    expect(snapshot_path).not_to be_nil
  end

  it "ships a local stand-in for the system specs" do
    expect(File).to exist(stand_in_path)
  end

  describe "the upstream snapshot" do
    it "still exposes every entry point the gem depends on" do
      required_entry_points.each do |name|
        expect(snapshot).to match(/api\.#{name}\s*=/),
                            "upstream render.js no longer defines #{name}; the gem's browser glue " \
                            "(and the local stand-in) must be revisited"
      end
    end

    it "still assigns the global the gem reads" do
      expect(snapshot).to include("global.wavebird=api")
    end

    it "still reads the slot endpoint from data-wavebird-endpoint" do
      # The view helper emits this attribute; the renderer POSTs to it.
      expect(snapshot).to include("data-wavebird-endpoint")
    end

    # INSTALL.md leads with the no-Stimulus path, and tells hosts to pass their
    # stable session id as an explicit body. That only works because
    # readTurnOptions treats an object carrying target/endpoint/body as options
    # and uses the given body instead of defaultBody()'s random uuid. If upstream
    # drops that branch, the documented path silently reverts to a fresh session
    # per turn — which looks like working code and quietly breaks attribution.
    it "still lets a caller pass an explicit request body" do
      expect(snapshot).to include("'body'in input"),
                          "upstream render.js no longer accepts an options object with a body; the " \
                          "no-Stimulus path in INSTALL.md can no longer carry a stable session_id"
      expect(snapshot).to include("body:isOptions&&'body'in input?input.body:defaultBody()")
    end

    it "still resolves a placement the way the gem's payload assumes" do
      WAVEBIRD_RESOLUTION_PATH.each do |what, source|
        expect(snapshot).to include(source),
                            "upstream render.js changed how it resolves a placement — #{what}. " \
                            "Wavebird::SlotPayload is shaped for the old path, so re-check it " \
                            "before refreshing the snapshot (decision #017)."
      end
    end
  end

  describe "the local stand-in" do
    it "implements every entry point the upstream snapshot exposes" do
      source = File.read(stand_in_path)

      required_entry_points.each do |name|
        expect(source).to match(/api\.#{name}\s*=/),
                          "the stand-in is missing #{name}, so the system specs would not exercise it"
      end
    end

    it "assigns the same global" do
      expect(File.read(stand_in_path)).to include("global.wavebird = api")
    end

    it "documents that it is a stand-in and names the snapshot it tracks" do
      source = File.read(stand_in_path)

      expect(source).to include("stand-in")
      expect(source).to include(File.basename(snapshot_path))
    end

    # The stand-in must resolve payloads the way upstream does, not the way the
    # gem happens to emit them. It was written the wrong way round once, which is
    # exactly why 18 green system specs said nothing about a payload the real
    # renderer could not read.
    it "ports the upstream resolution rather than reading the gem's own shape" do
      source = File.read(stand_in_path)

      expect(source).to include("function placementFrom(")
      expect(source).to include("function renderFrom(")
      expect(source).to include("renderFrom(placementFrom(")
    end
  end

  # --------------------------------------------------------------------------
  # Payload shape — the half of the contract that was missing.
  # --------------------------------------------------------------------------
  describe "the browser payload" do
    let(:fill_response) do
      Wavebird::Types::PlacementResponse.from_api(
        "status" => "ready",
        "placement" => {
          "asset_token" => "at_secret",
          "render" => { "strategy" => "hosted_frame", "frame_url" => frame_url,
                        "width" => 728, "height" => 90 }
        },
        "decision" => { "fill" => true }
      )
    end

    let(:fill_decision) do
      Wavebird::Types::Decision.from_api(
        "slot_id" => "slot_1", "status" => "ready", "fill" => true,
        "asset_token" => "at_secret",
        "creative" => { "width" => 300, "height" => 250, "sponsor_name" => "Acme" }
      )
    end

    before { Wavebird.configure { |c| c.api_base_url = "https://api.wavebird.ai" } }

    after { Wavebird.reset_configuration! }

    it "puts frame_url exactly where renderFrom looks for it (blocking path)" do
      expect(Wavebird::SlotPayload.call(fill_response).dig(:placement, :render, :frame_url))
        .to eq(frame_url)
    end

    it "puts frame_url on that same path on the async path" do
      expect(Wavebird::SlotPayload.call(fill_decision).dig(:placement, :render, :frame_url))
        .to eq(frame_url)
    end

    # The shape that shipped broken: render fields hoisted to the top level,
    # where placementFrom returns the payload itself and renderFrom finds neither
    # `p.render` nor `p.asset_token`, so it resolves null and paints nothing.
    it "never hoists render fields to the top level, where nothing reads them" do
      payload = Wavebird::SlotPayload.call(fill_response)

      %i[frame_url script_url strategy width height render].each do |flattened|
        expect(payload).not_to have_key(flattened)
      end
    end

    describe "resolved by the snapshot's own code" do
      before do
        skip "node is not installed; the shape assertions above still gate this" unless WAVEBIRD_NODE_AVAILABLE
      end

      it "resolves the blocking payload to the render the gem meant to send" do
        result = resolve(Wavebird::SlotPayload.call(fill_response))

        expect(result["start_turn_renders"]).to be(true)
        expect(result.dig("render", "frame_url")).to eq(frame_url)
      end

      it "resolves the async payload to the same render" do
        result = resolve(Wavebird::SlotPayload.call(fill_decision))

        expect(result["start_turn_renders"]).to be(true)
        expect(result.dig("render", "frame_url")).to eq(frame_url)
      end

      it "resolves a no-fill to nothing, so the slot is cleared" do
        expect(resolve(fill: false)["render"]).to be_nil
      end

      it "resolves a fill with no render block to nothing" do
        expect(resolve(fill: true)["render"]).to be_nil
      end

      # The regression itself, pinned: had this example existed, the flat payload
      # could not have shipped.
      it "would not have rendered the flat shape that shipped broken" do
        flat = { fill: true, frame_url: frame_url, width: 728, height: 90 }

        expect(resolve(flat)["render"]).to be_nil
      end
    end
  end

  # The snapshot is minified one top-level function per line, so the pure
  # resolution helpers lift out verbatim and run on their own — no DOM, no
  # network, no beacons, and no Ruby restatement of what they do.
  def snapshot_function(name)
    File.readlines(snapshot_path).find { |line| line.start_with?("function #{name}(") } ||
      raise("the render.js snapshot no longer defines a top-level #{name}()")
  end

  # Replays both routes a payload can take into the renderer, with upstream's own
  # code: startTurn's `placementFrom({decision: response})` guard (blocking path)
  # and renderPlacement's `renderFrom(placementFrom(options))` (async reveal).
  def resolution_harness
    functions = %w[str num scriptOrigin placementFrom renderFrom].map { |f| snapshot_function(f) }
    <<~JS
      #{functions.join}
      var payload = JSON.parse(require("fs").readFileSync(0, "utf8"));
      var viaStartTurn = placementFrom({ decision: payload });
      var resolved = renderFrom(placementFrom({ target: {}, decision: payload }));
      process.stdout.write(JSON.stringify({
        start_turn_renders: !!(viaStartTurn && viaStartTurn.render),
        render: resolved
      }));
    JS
  end

  def resolve(payload)
    out, status = Open3.capture2("node", "-e", resolution_harness, stdin_data: JSON.generate(payload))
    raise "node could not run the render.js resolution: #{out}" unless status.success?

    JSON.parse(out)
  end
end
