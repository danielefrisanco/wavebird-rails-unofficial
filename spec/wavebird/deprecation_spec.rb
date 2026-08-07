# frozen_string_literal: true

# Port of upstream's stage-3 timing deprecation (warnSdkDeprecation in
# createV1JobRequest). Upstream announces once per process, keyed per value; the
# gem announces through config.logger instead of console.warn.
RSpec.describe Wavebird::Deprecation do
  after { described_class.reset! }

  describe ".warn_once" do
    let(:logger) { instance_spy(Logger) }

    it "announces the message once, prefixed" do
      described_class.warn_once("k", "do not do that", logger)

      expect(logger).to have_received(:warn).with("[wavebird] do not do that")
    end

    it "stays silent on every repeat of the same key" do
      3.times { described_class.warn_once("k", "do not do that", logger) }

      expect(logger).to have_received(:warn).once
    end

    it "keys warnings independently" do
      described_class.warn_once("k1", "first", logger)
      described_class.warn_once("k2", "second", logger)

      expect(logger).to have_received(:warn).twice
    end

    # Upstream skips its registry entirely when there is no console.warn, so a
    # host that configures a logger later still gets the warning.
    it "does not consume the key when there is no logger" do
      described_class.warn_once("k", "do not do that", nil)
      described_class.warn_once("k", "do not do that", logger)

      expect(logger).to have_received(:warn).with("[wavebird] do not do that")
    end
  end

  describe ".reset!" do
    it "lets an already-announced key be announced again" do
      logger = instance_spy(Logger)
      described_class.warn_once("k", "again", logger)

      described_class.reset!
      described_class.warn_once("k", "again", logger)

      expect(logger).to have_received(:warn).twice
    end
  end
end
