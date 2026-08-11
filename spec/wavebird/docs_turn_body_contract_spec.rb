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

  # Every place the gem hands a host a turn-body snippet. The generator belongs
  # here for a reason: it was omitted from the first version of this list and
  # promptly shipped without `mode`, which the docs had just been corrected for.
  # A guard that covers most of the copies is a guard that reports success while
  # the uncovered one drifts.
  %w[
    INSTALL.md
    README.md
    examples/single_file_chat.rb
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

  # The specific pairing that broke: the helper emits the attribute, the endpoint
  # reads the param, and the plain path has to carry it between them.
  it "wires async mode from the helper's attribute to the endpoint's param" do
    expect(doc("app/helpers/wavebird/slot_helper.rb")).to include("wavebird_mode_value")
    expect(doc("app/controllers/wavebird/sponsor_slots_controller.rb")).to include("slot_params[:mode]")
    expect(doc("INSTALL.md")).to include("slot.dataset.wavebirdModeValue")
  end
end
