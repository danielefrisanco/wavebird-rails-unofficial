# frozen_string_literal: true

RSpec.describe Wavebird do
  it "has a semver version number" do
    expect(Wavebird::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end
end
