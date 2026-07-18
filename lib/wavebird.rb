# frozen_string_literal: true

require_relative "wavebird/version"
require_relative "wavebird/errors"
require_relative "wavebird/configuration"
require_relative "wavebird/types"

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

    # Resets the global configuration (used by tests).
    #
    # @return [void]
    def reset_configuration!
      @configuration = nil
    end
  end
end
