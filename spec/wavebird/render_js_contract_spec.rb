# frozen_string_literal: true

# The system specs drive a local stand-in for wavebird's hosted render.js
# (spec/dummy/public/v1/render.js), because the real script cannot be fetched
# with net connections disabled. That stand-in is only trustworthy while it
# matches the real contract, so this spec pins both sides against the snapshot in
# docs/upstream/.
#
# It is a *contract* check, not a behavioral one: it asserts the entry points the
# gem depends on still exist upstream and are still stubbed locally. If wavebird
# ships a renamed or removed entry point, refreshing the snapshot fails this spec
# rather than silently invalidating every system test.
RSpec.describe "hosted render.js contract", :aggregate_failures do # rubocop:disable RSpec/DescribeClass
  # The surface the gem actually drives: the Stimulus controller calls withTurn
  # (both host entry points, decision #008) and renderPlacement/clearPlacement
  # for the async reveal (decision #009). startTurn is withTurn's own primitive.
  let(:required_entry_points) { %w[withTurn startTurn renderPlacement clearPlacement] }

  let(:snapshot_path) do
    Dir.glob(File.expand_path("../../docs/upstream/render-js-snapshot-*.js", __dir__)).max
  end
  let(:stand_in_path) { File.expand_path("../dummy/public/v1/render.js", __dir__) }

  it "has a dated upstream snapshot to check against" do
    expect(snapshot_path).not_to be_nil
  end

  it "ships a local stand-in for the system specs" do
    expect(File).to exist(stand_in_path)
  end

  describe "the upstream snapshot" do
    it "still exposes every entry point the gem depends on" do
      source = File.read(snapshot_path)

      required_entry_points.each do |name|
        expect(source).to match(/api\.#{name}\s*=/),
                          "upstream render.js no longer defines #{name}; the gem's browser glue " \
                          "(and the local stand-in) must be revisited"
      end
    end

    it "still assigns the global the gem reads" do
      expect(File.read(snapshot_path)).to include("global.wavebird=api")
    end

    it "still reads the slot endpoint from data-wavebird-endpoint" do
      # The view helper emits this attribute; the renderer POSTs to it.
      expect(File.read(snapshot_path)).to include("data-wavebird-endpoint")
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
  end
end
