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
  # Deliberately not pinned to the full argument list. On 2026-08-23 upstream
  # added `authoritative_consent:` to this call, which is a *new precondition*
  # (plan v3 item A), not a change to how the response is resolved. Pinning the
  # whole call made this spec fail for the resolution reason it does not have.
  # What #017 needs guarded is that the endpoint response is handed over whole.
  "startTurn hands the whole endpoint response to renderPlacement" =>
    "api.renderPlacement({target:target,decision:decision",
  "renderPlacement re-resolves from its own options" =>
    "var p=placementFrom(options);var r=renderFrom(p)"
}.freeze

# Gates the stand-in deliberately does not implement, each with the reason. The
# allowlist is the point: a gate that turns up in the snapshot and is *not* here
# fails the drift check, so skipping one has to be a decision someone wrote down
# rather than an omission nobody noticed.
UNIMPLEMENTED_GATES = {
  # Guards sendRenderBeacon. The stand-in has no beacons at all (#012a): they
  # post to a blocked host and are the renderer's own concern, not part of the
  # surface this gem drives. With nothing to guard, the guard has no meaning.
  "isRenderActive" => "the stand-in sends no beacons"
}.freeze

RSpec.describe "hosted render.js contract", :aggregate_failures do # rubocop:disable RSpec/DescribeClass
  # The surface the gem actually drives: the Stimulus controller calls withTurn
  # (both host entry points, decision #008) and renderPlacement/clearPlacement
  # for the async reveal (decision #009). startTurn is withTurn's own primitive.
  let(:required_entry_points) { %w[withTurn startTurn renderPlacement clearPlacement] }
  let(:frame_url) { "https://api.wavebird.ai/v1/render/at_secret" }

  # Plain methods rather than `let`s: they are paths and file reads, not per-example
  # fixtures, and the payload group below is already at RuboCop's memoized-helper cap.
  # There are now two snapshots, and they answer different questions.
  # `snapshot_path` is the newest -- what wavebird serves today, and therefore
  # what the gem's own assumptions must hold against. `tracked_snapshot_path` is
  # the one the stand-in declares it implements, which may lag. The gap between
  # them is drift, and the example at the bottom of this file is where it shows.
  def snapshot_path
    Dir.glob(File.expand_path("../../docs/upstream/render-js-snapshot-*.js", __dir__)).max
  end

  # Read as binary-safe text: the served file contains a NUL byte, which makes
  # grep report nothing on it and cost a wrong conclusion during the 2026-08-23
  # investigation.
  def snapshot
    File.read(snapshot_path, encoding: "BINARY").force_encoding("UTF-8").scrub
  end

  # Helpers the snapshot negates inside a guard — `if(!consentAllowsAdActivity(`,
  # `if(!p||!p.render)`. Restricted to camelCase names so the scan picks up the
  # renderer's own predicates rather than every negated local variable.
  def snapshot_guards
    snapshot.scan(/if\s*\(\s*!\s*([a-z][A-Za-z]+)\s*\(/).flatten.uniq
  end

  def tracked_snapshot_path
    named = File.read(stand_in_path)[/render-js-snapshot-[\d-]+\.js/]
    named && File.expand_path("../../docs/upstream/#{named}", __dir__)
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

    it "documents that it is a stand-in and names a snapshot that exists" do
      source = File.read(stand_in_path)

      expect(source).to include("stand-in")
      expect(tracked_snapshot_path).not_to be_nil, "the stand-in names no snapshot at all"
      expect(File).to exist(tracked_snapshot_path)
    end

    # The drift check this file did not have, and the reason the gem shipped a
    # browser integration that could not run: the stand-in implements the
    # contract *as of the snapshot it tracks*, so once a newer snapshot exists,
    # every system spec is validating the gem against a contract wavebird has
    # already replaced. The names of the entry points do not change when this
    # happens -- the preconditions do -- which is why nothing else here fires.
    it "tracks the newest snapshot, or the system suite is testing a dead contract" do
      expect(File.basename(tracked_snapshot_path)).to eq(File.basename(snapshot_path))
    end

    # The guard that did not exist, and the reason the gem shipped a browser
    # integration that could not run. Entry-point *names* survive a vendor
    # change; preconditions do not. wavebird added a consent gate on 2026-08-23,
    # this stand-in did not have it, and 27 green system examples said nothing.
    #
    # Every helper the snapshot calls inside an `if(!...)` is a way the real
    # renderer declines to act. A stand-in missing one lets the suite pass on a
    # turn the real script would refuse, so the set is compared rather than
    # spot-checked: a gate added upstream fails here by appearing in the diff,
    # without anyone having to predict what it will be called.
    it "enforces every gate the upstream snapshot enforces" do
      # Definitions, not mentions: scanning for calls matched the guard's own
      # call sites, so deleting the function body from the stand-in still passed.
      implemented = File.read(stand_in_path).scan(/function\s+(\w+)\s*\(/).flatten.uniq
      missing = snapshot_guards - implemented - UNIMPLEMENTED_GATES.keys

      expect(missing).to be_empty,
                         "upstream render.js refuses a turn via #{missing.join(', ')}, which the " \
                         "stand-in does not implement. Until it does, the system specs exercise a " \
                         "contract the live renderer has already replaced — the exact failure that " \
                         "produced plan v3."
    end

    # The stand-in must resolve payloads the way upstream does, not the way the
    # gem happens to emit them. It was written the wrong way round once, which is
    # exactly why 18 green system specs said nothing about a payload the real
    # renderer could not read.
    it "ports the upstream resolution rather than reading the gem's own shape" do
      source = File.read(stand_in_path)

      expect(source).to include("function placementFrom(")
      expect(source).to include("function renderFrom(")
      # Either spelling of the same composition: inlined, or via a named local
      # (renderPlacement needs the placement itself as well, to read the consent
      # it may carry, so it names it).
      expect(source).to match(/renderFrom\(\s*(placementFrom\(|placement\b)/),
                        "the stand-in no longer resolves a render from placementFrom's result, " \
                        "so it is reading some other shape than the one upstream reads"
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
