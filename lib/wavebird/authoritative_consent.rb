# frozen_string_literal: true

module Wavebird
  # Resolves and validates the consent object the hosted renderer requires
  # before it will run a turn.
  #
  # **Why this exists.** On 2026-08-23 wavebird's hosted +render.js+ began gating
  # every turn on an +authoritative_consent+ object. Without a valid one,
  # +startTurn+ returns immediately: no request to the host's endpoint, no error,
  # nothing in the console. The gem sent none, so the browser integration was
  # inert against the live renderer while the whole test suite stayed green
  # (+wavebird-rails-plan-v3.md+).
  #
  # **It is the host's assertion, not wavebird's verification.** The renderer's
  # check is purely local — it makes no network call, and the object is never
  # sent in any request body. It gates four things client-side: the turn before
  # its fetch, the turn again after the fetch resolves, +renderPlacement+, and
  # every beacon. So this object says "my consent management system says this
  # visitor agreed", and only the host can say that. The gem never invents it and
  # never stores it.
  #
  # Configure a callable, resolved fresh on every request:
  #
  #   Wavebird.configure do |config|
  #     config.authoritative_consent = lambda do
  #       record = MyConsentStore.for(Current.session)
  #       { lifecycle_state: record.granted? ? "granted" : "denied",
  #         expires_at_ms: record.expires_at.to_i * 1000 }
  #     end
  #   end
  #
  # @see Configuration#authoritative_consent
  module AuthoritativeConsent
    # The only value the renderer treats as permission. Any other lifecycle state
    # is a valid answer — it means "do not run an auction" — not an error.
    GRANTED = "granted"

    # Mirrors +consentAllowsAdActivity+ in the hosted renderer
    # (+render-js-snapshot-2026-08-23.js+). Every rule here exists because the
    # renderer enforces it; loosening any of them produces an object the renderer
    # silently rejects, which is the failure this class exists to make loud.
    REQUIRED_INTEGERS = %i[revision updated_at_ms expires_at_ms].freeze

    module_function

    # @param config [Configuration]
    # @param now_ms [Integer] injectable clock, so expiry is testable
    # @return [Hash, nil] a hash the renderer will accept, or nil
    def resolve(config, now_ms: current_time_ms)
      source = config.authoritative_consent
      return announce_absent(config) if source.nil?

      value = call_source(source, config)
      return nil if value.nil?

      normalize(value, config, now_ms)
    end

    # A resolver that raises must not take down the host's page: the ad path
    # never breaks a chat turn (#003). It degrades to "no consent", which is the
    # same outcome as not configuring one — the slot stays empty.
    def call_source(source, config)
      source.respond_to?(:call) ? source.call : source
    rescue StandardError => e
      report(config, "config.authoritative_consent raised #{e.class}: #{e.message}; " \
                     "no ad will be requested until it returns a valid consent object")
      nil
    end

    # Fills in the two bookkeeping fields and rejects anything the renderer would
    # refuse. +lifecycle_state+ and +expires_at_ms+ are never defaulted: they are
    # the assertion itself, and inventing them would let the gem claim a consent
    # nobody gave.
    def normalize(value, config, now_ms)
      hash = symbolize(value)
      return nil if hash.nil?

      hash = { revision: 1, updated_at_ms: now_ms }.merge(hash)
      return nil unless granted?(hash, config) && valid_integers?(hash, config, now_ms)

      hash.slice(:lifecycle_state, :revision, :updated_at_ms, :expires_at_ms)
    end

    def symbolize(value)
      return nil unless value.respond_to?(:to_h)

      value.to_h.transform_keys(&:to_sym)
    rescue TypeError, ArgumentError
      nil
    end

    # A non-granted state is a normal answer, not a misconfiguration, so it is
    # silent: the visitor declined, and the slot stays empty as it should. A
    # *missing* state is a bug in the host's resolver and is reported.
    def granted?(hash, config)
      state = hash[:lifecycle_state].to_s
      return true if state == GRANTED
      return false unless state.empty?

      report(config, "config.authoritative_consent returned no lifecycle_state; the hosted " \
                     "renderer requires #{GRANTED.inspect} and will refuse the turn without it")
      false
    end

    def valid_integers?(hash, config, now_ms)
      REQUIRED_INTEGERS.each do |key|
        value = hash[key]
        next if integer?(value) && (key != :revision || value >= 1)

        report_invalid_field(config, key, value)
        return false
      end
      return true if hash[:expires_at_ms] > now_ms

      report(config, "config.authoritative_consent returned expires_at_ms in the past; " \
                     "the hosted renderer will refuse the turn and no ad will be requested")
      false
    end

    def report_invalid_field(config, key, value)
      report(config, "config.authoritative_consent returned #{key}=#{value.inspect}, which the " \
                     "hosted renderer will reject (#{key} must be an integer" \
                     "#{' >= 1' if key == :revision}); no ad will be requested")
    end

    def integer?(value) = value.is_a?(Integer)

    # Announced once per process, not per request: an unconfigured host is not
    # broken, it just has no ads, and warning on every page render would be
    # noise. A *misconfigured* one is reported every time — see #028 for the same
    # reasoning about a persistently broken hook.
    # Reuses {Deprecation.warn_once} because it is the gem's once-per-process
    # logger channel and {Wavebird.reset_configuration!} already clears it — a
    # second registry would need its own reset wiring and could desync from it.
    # This is a configuration notice, not a deprecation.
    def announce_absent(config)
      Deprecation.warn_once("authoritative_consent:absent",
                            "config.authoritative_consent is not set, so no ad will ever be " \
                            "requested — the hosted renderer refuses every turn without it. " \
                            "See INSTALL.md 'Consent'.",
                            config.logger)
      nil
    end

    def report(config, message)
      config.logger&.warn("[wavebird] #{message}")
      nil
    end

    def current_time_ms = (Time.now.to_f * 1000).to_i

    # {resolve} is the whole public surface; everything else is how it gets
    # there. Declared explicitly because `module_function` would otherwise
    # publish all of it, and a helper that is public by accident is a helper
    # someone depends on by accident.
    private_class_method :call_source, :normalize, :symbolize, :granted?, :valid_integers?,
                         :report_invalid_field, :integer?, :announce_absent, :report, :current_time_ms
  end
end
