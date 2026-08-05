# frozen_string_literal: true

module Wavebird
  # Port of upstream +deprecation.ts+ (+warnSdkDeprecation+): announces a
  # deprecation once per process, keyed exactly as upstream keys it
  # (+stage3Timing:before+), so a warning triggered on every chat turn does not
  # flood the host's log.
  #
  # Upstream writes to +console.warn+ and skips the registry entirely when no
  # console exists. The gem writes to +config.logger+ — the channel every other
  # diagnostic uses — and likewise leaves the key unannounced when the host
  # configured no logger, so the warning is not lost for a host that adds one
  # later.
  module Deprecation
    module_function

    # @param key [String] dedupe key, one per distinct deprecation
    # @param message [String] announced verbatim, once, prefixed with +[wavebird]+
    # @param logger [Logger, nil] the host's logger; +nil+ silences the warning
    #   without consuming the key
    # @return [void]
    def warn_once(key, message, logger)
      return if logger.nil?
      return unless announced.add?(key)

      logger.warn("[wavebird] #{message}")
    end

    # @return [Set<String>] deprecation keys already announced in this process
    def announced
      @announced ||= Set.new
    end

    # Forgets every announced key. Called by {Wavebird.reset_configuration!} so a
    # test process can observe a first-time warning more than once.
    #
    # @return [void]
    def reset!
      announced.clear
    end
  end
end
