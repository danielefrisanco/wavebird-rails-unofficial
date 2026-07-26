# frozen_string_literal: true

require_relative "client"

module Wavebird
  # Fail-silent, Rails-facing wrapper around {Wavebird::Client} (decision #003).
  #
  # The upstream TypeScript SDK's public methods never throw: a failed sponsor
  # slot must never break the host's chat flow. {Wavebird::Client} is the
  # opposite by design — it raises typed {Wavebird::Error}s so callers who want
  # them can catch them. This facade restores the upstream posture on top: every
  # public method catches {Wavebird::Error}, reports it through
  # +config.on_error+/+config.logger+ (the same channel the polling ladder uses),
  # and returns a first-class "hide the slot and continue" outcome instead of
  # propagating.
  #
  # +Wavebird.client+ returns an instance of this facade — the fail-silent layer
  # is the public default; reach for {Wavebird::Client} directly only when you
  # want typed exceptions.
  class Facade
    # @return [Wavebird::Configuration]
    attr_reader :config

    # @return [Wavebird::Client] the raising low-level client this wraps
    attr_reader :client

    # @param config [Wavebird::Configuration] defaults to the global configuration
    # @param client [Wavebird::Client] injectable for tests
    def initialize(config: Wavebird.configuration, client: nil)
      @config = config
      @client = client || Client.new(config: config)
    end

    # Creates a placement and waits for its first decision, never raising.
    #
    # On any {Wavebird::Error} (network, timeout, API error, misconfiguration)
    # the error is reported and a no-fill {Types::PlacementResponse} is returned,
    # so the caller's rendering path is identical whether the auction genuinely
    # returned no fill or wavebird was simply unreachable — hide the slot and
    # continue. See {Client#create_placement} for the keyword arguments.
    #
    # @return [Types::PlacementResponse] a real response, or a synthetic no-fill
    #   on failure ({Types::PlacementResponse#no_fill?} is true either way)
    def create_placement(**)
      client.create_placement(**)
    rescue Error => e
      report(e)
      no_fill_response
    end

    # Records a beacon, never raising. Returns +nil+ when it could not be sent.
    #
    # @return [Types::BeaconResult, nil]
    def record_beacon(**)
      client.record_beacon(**)
    rescue Error => e
      report(e)
      nil
    end

    private

    # A synthetic "no fill" response, shaped like a genuine empty auction so the
    # rendering path can't tell a failure from an honest no-fill.
    def no_fill_response
      Types::PlacementResponse.from_api("status" => "no_fill", "placement" => nil, "decision" => nil)
    end

    # Reports a swallowed error through the same fail-silent channel the polling
    # ladder uses: the +on_error+ observer (guarded — an observer that raises
    # must not turn a hidden slot into a crash) and the redacting logger.
    def report(error)
      begin
        config.on_error&.call(error)
      rescue StandardError
        nil # observers must never break the host flow (upstream behavior)
      end
      config.logger&.warn("[wavebird] #{error.class}: #{error.message}")
    end
  end
end
