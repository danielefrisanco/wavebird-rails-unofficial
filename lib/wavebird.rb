# frozen_string_literal: true

require_relative "wavebird/version"
require_relative "wavebird/deprecation"
require_relative "wavebird/errors"
require_relative "wavebird/boot_check"
require_relative "wavebird/configuration"
require_relative "wavebird/types"
require_relative "wavebird/decision_normalizer"
require_relative "wavebird/client"
require_relative "wavebird/facade"
require_relative "wavebird/slot_payload"

# Fail loudly if this was required from an asset-pipeline / browser-bundle tree:
# the client holds the secret key and must stay server-side (build prompt §4).
Wavebird::BootCheck.assert_server_side_require!

# Rails client and Hotwire integration for the wavebird Compute Sponsoring API
# (https://wavebird.ai). Ported from the original public wavebird TypeScript
# SDK (https://github.com/wavebird-ai/wavebird).
module Wavebird
  class << self
    # @return [Wavebird::Configuration] the global configuration
    def configuration
      @configuration ||= Configuration.new
    end

    # Configures the gem.
    #
    # @example
    #   Wavebird.configure do |c|
    #     c.secret_key = ENV.fetch("WAVEBIRD_SECRET_KEY")
    #     c.client_id  = ENV.fetch("WAVEBIRD_CLIENT_ID")
    #   end
    #
    # @yieldparam config [Wavebird::Configuration]
    # @return [Wavebird::Configuration]
    def configure
      yield configuration
      configuration
    end

    # The public, fail-silent client (parity with the upstream SDK: a failed
    # sponsor slot never breaks the host flow — decision #003). Memoized against
    # the global configuration; reset by {reset_configuration!}.
    #
    # For typed exceptions instead, instantiate {Wavebird::Client} directly.
    #
    # @return [Wavebird::Facade]
    def client
      @client ||= Facade.new(config: configuration)
    end

    # Resets the global configuration (used by tests). Also clears the
    # once-per-process deprecation registry, so a test that expects a first-time
    # warning is not silenced by an earlier example that already triggered it.
    #
    # @return [void]
    def reset_configuration!
      @configuration = nil
      @client = nil
      Deprecation.reset!
    end
  end
end
