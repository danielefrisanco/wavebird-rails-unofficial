# frozen_string_literal: true

# INSTALL.md and the README lead with the plain-JavaScript path, which asks the
# host to build the request body by hand from the slot's data attributes. That
# only stays true if the documented body carries every field the Stimulus
# controller forwards — and the two live in different files, so nothing but this
# spec keeps them together.
#
# The failure it guards against is silent by construction: a missing field does
# not raise, it changes what the endpoint decides. `mode` went missing exactly
# this way — a slot rendered `async: true` was served on the blocking path, still
# filling, while its Turbo Stream subscription sat idle. Found by review, not by
# the suite, because every layer was individually correct.
RSpec.describe "documented turn body", :aggregate_failures do # rubocop:disable RSpec/DescribeClass
  # A method rather than a constant: a constant declared inside the block leaks
  # to the enclosing scope, which RuboCop flags and which has bitten this repo
  # before (the Types::RateLimited constants under Data.define).
  def root = File.expand_path("../..", __dir__)

  # The keys the Stimulus controller puts on the request body, read from its
  # source rather than restated here — restating is how the drift starts.
  def controller_body_keys
    source = doc("app/javascript/controllers/wavebird_controller.js")
    source.scan(/body\.(\w+)\s*=/).flatten.uniq
  end

  def doc(relative) = File.read(File.join(root, relative))

  # The text around each `withTurn(` call: enough before it to catch options
  # assembled into a variable first (the Stimulus controller builds `input`,
  # then passes it), and enough after to catch an inline options literal.
  def turn_call_sites(contents)
    sites = contents.enum_for(:scan, /withTurn\s*\(/).map do
      offset = Regexp.last_match.begin(0)
      without_comments(contents[[offset - 600, 0].max...(offset + 400)])
    end
    sites.select { |site| turn_start?(site) }
  end

  # Comments explaining *why* consent is needed sit right beside the call in
  # every one of these files, and they contain the word. Left in, they satisfy
  # the check on their own: verified by deleting the code line from the Stimulus
  # controller and watching the guard still pass. Only code counts.
  def without_comments(site)
    site.gsub(%r{//[^\n]*}, "")
  end

  # These files also *discuss* withTurn in prose ("withTurn also takes a
  # selector"), and prose does not need a consent object. A real turn start is
  # one that passes options: either an inline literal carrying `target:`, or
  # options assembled into a variable first, as the Stimulus controller does.
  def turn_start?(site)
    site.include?("target:") || site.match?(/withTurn\s*\(\s*input\b/)
  end

  # The dataset property the plain path reads for a given body key:
  # session_id -> slot.dataset.wavebirdSessionIdValue. Asserting on this rather
  # than on the bare key matters — "mode" occurs all over INSTALL.md as prose
  # ("async delivery mode"), so a substring check on the key alone passes even
  # with the code line deleted, which is exactly the regression being guarded.
  def dataset_reference(key)
    camel = key.split("_").map(&:capitalize).join
    "dataset.wavebird#{camel}Value"
  end

  it "reads a non-empty set of keys from the controller" do
    # Guards the guard: a refactor that renamed the body variable would empty the
    # scan and make every assertion below vacuously pass.
    expect(controller_body_keys).to include("session_id", "position", "mode")
  end

  # Every place the gem hands a host a turn-body snippet to copy. The generator
  # belongs here for a reason: it was omitted from the first version of this list
  # and promptly shipped without `mode`, which the docs had just been corrected
  # for. A guard covering most of the copies reports success while the uncovered
  # one drifts.
  #
  # examples/chat_hotwire.rb is deliberately absent: on the Stimulus path the
  # controller builds the body from its own values, so the example has no
  # snippet to keep in step. Adding it here would fail for the right reason and
  # the wrong cause.
  #
  # examples/chat_react.rb *is* here, for the mirror-image reason: its
  # `useWavebirdTurn` hook builds the body by hand from the same dataset
  # attributes, exactly as the plain path does. React is a third copy of this
  # snippet, and a third copy is a third chance to drift.
  %w[
    INSTALL.md
    README.md
    examples/chat_plain.rb
    examples/chat_react.rb
    lib/generators/wavebird/install/install_generator.rb
  ].each do |path|
    it "#{path} builds the turn body from every field the Stimulus controller sends" do
      contents = doc(path)

      controller_body_keys.each do |key|
        expect(contents).to include(dataset_reference(key)),
                            "#{path} builds a turn body without #{key.inspect}, which the Stimulus " \
                            "controller does send. A host on the plain-JavaScript path would silently " \
                            "get different behaviour from one on the Stimulus path."
      end
    end
  end

  # `authoritative_consent` is not a body key -- it is a *turn option* -- so the
  # loop above cannot see it. It gets its own guard for the same reason `mode`
  # has one, and a sharper one: a body key that goes missing changes what the
  # auction decides, while this one stops the auction happening at all. The
  # hosted renderer checks it before fetching anything and returns a null
  # decision, so a path that forgets it makes no request, raises nothing, and
  # logs nothing. That is precisely how the gem shipped a browser integration
  # that could not run (plan v3).
  #
  # Every place the gem hands a host JavaScript that starts a turn:
  %w[
    INSTALL.md
    README.md
    examples/chat_plain.rb
    examples/chat_react.rb
    lib/generators/wavebird/install/install_generator.rb
    app/javascript/controllers/wavebird_controller.js
  ].each do |path|
    it "#{path} passes authoritative_consent into the turn" do
      contents = doc(path)

      expect(contents).to include("wavebirdConsentValue"),
                          "#{path} never reads the consent the view helper serialises onto the " \
                          "slot, so every turn it starts is refused by the hosted renderer " \
                          "silently -- no request, no error, nothing in the console."
      # Checked at the call site, not anywhere in the file. Two weaker versions
      # of this guard passed with the code deleted: a bare `include` matched the
      # word in prose, and an assignment regex matched the *server-side*
      # `config.authoritative_consent =` that the examples also contain. Only the
      # neighbourhood of the `withTurn` call says what is actually passed to it.
      expect(turn_call_sites(contents)).not_to be_empty,
                                               "#{path} documents no withTurn call to check"
      expect(turn_call_sites(contents)).to all(include("authoritative_consent")),
                                           "#{path} starts a turn without authoritative_consent, so " \
                                           "the hosted renderer refuses it silently -- no request, " \
                                           "no error, nothing in the console."
    end
  end

  # The helper is the single source of that attribute; without it every path
  # above reads undefined and the guards pass while nothing works.
  it "emits the consent attribute the documented paths read back" do
    expect(doc("app/helpers/wavebird/slot_helper.rb")).to include("wavebird_consent_value")
    expect(doc("lib/wavebird/slot_payload.rb")).to include("authoritative_consent"),
                                                   "the async reveal path carries consent in " \
                                                   "the placement payload; renderPlacement " \
                                                   "reads it from there"
  end

  # The specific pairing that broke: the helper emits the attribute, the endpoint
  # reads the param, and the plain path has to carry it between them.
  it "wires async mode from the helper's attribute to the endpoint's param" do
    expect(doc("app/helpers/wavebird/slot_helper.rb")).to include("wavebird_mode_value")
    expect(doc("app/controllers/wavebird/sponsor_slots_controller.rb")).to include("slot_params[:mode]")
    expect(doc("INSTALL.md")).to include("slot.dataset.wavebirdModeValue")
  end
end
