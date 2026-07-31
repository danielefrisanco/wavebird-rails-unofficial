# frozen_string_literal: true

RSpec.describe Wavebird::Railtie do
  it "is a Rails railtie, so its initializers run at host boot" do
    expect(described_class.ancestors).to include(Rails::Railtie)
  end

  it "registers the boot check as an initializer" do
    expect(described_class.initializers.map(&:name)).to include("wavebird.boot_check")
  end

  it "delegates the initializer to BootCheck.run" do
    initializer = described_class.initializers.find { |i| i.name == "wavebird.boot_check" }
    app = instance_double(Rails::Application)
    allow(Wavebird::BootCheck).to receive(:run)

    initializer.run(app)

    expect(Wavebird::BootCheck).to have_received(:run).with(app)
  end

  it "has already run cleanly in this suite's booted application" do
    # spec/support/rails_app.rb boots a real in-memory application with the gem
    # loaded; reaching this example at all means the guard did not raise.
    expect(WavebirdSpec::Application).to be_initialized
  end
end
