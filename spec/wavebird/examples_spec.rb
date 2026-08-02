# frozen_string_literal: true

# The files in examples/ are meant to be copy-pasted into a fresh Rails app
# (acceptance §4), which makes them the one piece of documentation that can be
# *wrong* rather than merely stale. This spec pins them to the real API: if a
# config option or a view helper is renamed, the example stops matching and this
# fails, instead of shipping a quickstart that raises NoMethodError in a user's
# app on their first try.
EXAMPLE_ROOT = File.expand_path("../../examples/chat_with_sponsored_slot", __dir__)

RSpec.describe "examples/chat_with_sponsored_slot", :aggregate_failures do # rubocop:disable RSpec/DescribeClass
  let(:example_root) { EXAMPLE_ROOT }

  ruby_files = Dir.glob(File.join(EXAMPLE_ROOT, "**/*.rb"))

  it "ships the files the example README lists" do
    %w[
      config/initializers/wavebird.rb
      config/routes.rb
      app/controllers/application_controller.rb
      app/controllers/chats_controller.rb
      app/views/chats/show.html.erb
    ].each { |path| expect(File).to exist(File.join(example_root, path)) }
  end

  ruby_files.each do |path|
    it "parses as valid Ruby: #{Pathname.new(path).relative_path_from(EXAMPLE_ROOT)}" do
      expect { RubyVM::AbstractSyntaxTree.parse_file(path) }.not_to raise_error
    end
  end

  it "configures only real Configuration options" do
    source = File.read(File.join(example_root, "config/initializers/wavebird.rb"))
    options = source.scan(/^\s*config\.(\w+)\s*=/).flatten

    expect(options).not_to be_empty
    options.each do |option|
      expect(Wavebird::Configuration.public_method_defined?(:"#{option}="))
        .to be(true), "examples/ sets config.#{option}, which Wavebird::Configuration does not define"
    end
  end

  it "calls only real view helpers from the example view" do
    source = File.read(File.join(example_root, "app/views/chats/show.html.erb"))
    helpers = source.scan(/\b(wavebird_\w+)/).flatten.uniq - %w[wavebird_session_id]

    expect(helpers).to include("wavebird_slot", "wavebird_render_script_tag")
    helpers.each do |helper|
      expect(Wavebird::SlotHelper.public_method_defined?(helper))
        .to be(true), "examples/ calls #{helper}, which Wavebird::SlotHelper does not define"
    end
  end

  it "passes wavebird_slot only keywords the helper accepts" do
    source = File.read(File.join(example_root, "app/views/chats/show.html.erb"))
    keywords = source[/wavebird_slot(.*?)%>/m].scan(/(\w+):/).flatten

    accepted = Wavebird::SlotHelper.instance_method(:wavebird_slot).parameters
                                   .filter_map { |type, name| name.to_s if %i[key keyreq].include?(type) }

    expect(keywords).to include("endpoint") # guards against the scan silently matching nothing
    expect(keywords - accepted).to be_empty
  end

  it "reaches the session id through the documented concern" do
    controller = File.read(File.join(example_root, "app/controllers/application_controller.rb"))

    expect(controller).to include("include Wavebird::SessionId")
    # The engine isolates its namespace, so helpers are not mixed in for free —
    # omitting this line is the failure mode a copy-paste user would hit first.
    expect(controller).to include("helper Wavebird::SlotHelper")
    expect(Wavebird::SessionId.public_method_defined?(:wavebird_session_id)).to be(true)
  end

  it "mounts the engine at the prefix the view's route helper assumes" do
    routes = File.read(File.join(example_root, "config/routes.rb"))

    expect(routes).to match(/mount Wavebird::Engine\s*=>/)
    expect(Wavebird::Engine.routes.url_helpers).to respond_to(:sponsor_slot_path)
  end
end
