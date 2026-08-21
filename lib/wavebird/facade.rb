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
  #
  # Every method {Wavebird::Client} exposes is mirrored here, because upstream's
  # whole public surface is fail-silent (+reportGeneration+ is documented
  # +@throws Never+): a method reachable only in its raising form would let the
  # ad path break the host's flow, which is exactly what this layer exists to
  # prevent.
  #
  # Argument errors are *not* swallowed. An event outside the canonical enum is
  # a caller bug, not a wavebird failure, and upstream's compiler rejects it
  # before the call is ever made — so +ArgumentError+ propagates here too.
  class Facade
    # Reason code upstream's fail-silent beacon fallback carries
    # (+fallbackBeacon+ in wavebird-client.ts).
    FAIL_SILENT_REASON_CODE = "SDK_FAIL_SILENT"

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

    # Creates a job without waiting for decisions, never raising — the
    # non-blocking entry point for async delivery mode (decision #001). Returns
    # +nil+ when the job could not be created, so the caller simply skips
    # enqueuing the poll and the slot stays hidden. See {Client#create_job}.
    #
    # A rate limit is **not** a failure here: upstream's +createJob+ answers a
    # 429 with a typed +{error: "rate_limit_exceeded", retry_after_ms}+ value and
    # a warning, never through +onError+. This returns the same outcome as a
    # {Types::RateLimited}, so a caller can back off instead of guessing why the
    # job is missing. Both it and {Types::AcceptedJob} answer +rate_limited?+.
    #
    # @return [Types::AcceptedJob, Types::RateLimited, nil]
    def create_job(**)
      client.create_job(**)
    rescue RateLimitedError => e
      report_rate_limit(e)
      Types::RateLimited.from_retry_after(e.retry_after)
    rescue Error => e
      report(e)
      nil
    end

    # Polls a slot once, never raising. On any {Wavebird::Error} the error is
    # reported and a pending {Types::Decision} is returned — upstream's
    # +pollDecisionOnce+ fallback, which lets a caller driving its own ladder
    # keep polling. See {Client#poll_decision}; prefer {#await_decision} unless driving your own loop.
    #
    # @param slot_id [String]
    # @return [Types::Decision] a real decision, or a synthetic pending one
    def poll_decision(slot_id, **)
      client.poll_decision(slot_id, **)
    rescue Error => e
      report(e)
      pending_decision(slot_id)
    end

    # Polls a slot until its decision is ready, never raising. On any
    # {Wavebird::Error} — including {DecisionTimeoutError} when the polling budget
    # is exhausted — the error is reported and a *pending* {Types::Decision} is
    # returned, matching upstream's +fallbackDecision+ (+status: "pending"+,
    # +fill: nil+): the auction never reached a verdict, so the result says so
    # rather than claiming a no-fill that never happened.
    #
    # Rendering is unaffected either way — a pending decision is not a fill, so
    # the slot stays hidden and the host's flow continues (decision #003).
    #
    # @param slot_id [String]
    # @return [Types::Decision] a real ready decision, or a synthetic pending one
    def await_decision(slot_id)
      client.await_decision(slot_id)
    rescue Error => e
      report(e)
      pending_decision(slot_id)
    end

    # Records a beacon, never raising. On failure the error is reported and
    # upstream's fail-silent acknowledgement is returned —
    # +{accepted: false, reason_code: "SDK_FAIL_SILENT"}+ — so callers always get
    # a {Types::BeaconResult} to read +accepted?+ from. See {Client#record_beacon}.
    #
    # @return [Types::BeaconResult]
    def record_beacon(**)
      client.record_beacon(**)
    rescue Error => e
      report(e)
      fail_silent_beacon
    end

    # Reports a generation lifecycle event, never raising — upstream's
    # +reportGeneration+ is fire-and-forget and documented +@throws Never+, and
    # it is called from inside the host's generation loop, where an exception
    # would take the chat turn down with it. See {Client#report_generation}.
    #
    # @param job_id [String]
    # @param event [String, Symbol] one of started|finished|failed
    # @return [Boolean] +true+ when the report was accepted, +false+ on failure
    def report_generation(job_id, event, **)
      client.report_generation(job_id, event, **)
    rescue Error => e
      report(e)
      false
    end

    # Syncs session/user-level consent, never raising. Returns +nil+ when the
    # sync failed — consent still travels per request via +consent:+, which does
    # not depend on this call. See {Client#record_consent}.
    #
    # @return [Types::ConsentState, nil]
    def record_consent(**)
      client.record_consent(**)
    rescue Error => e
      report(e)
      nil
    end

    # Exchanges the publishable key for a browser activation token, never
    # raising. Returns +nil+ when no token could be obtained, so the caller
    # serves a page without a browser-side wavebird session rather than a 500.
    # See {Client#activate_browser}.
    #
    # @return [Types::BrowserActivation, nil]
    def activate_browser(**)
      client.activate_browser(**)
    rescue Error => e
      report(e)
      nil
    end

    # Fetches the non-secret runtime project configuration, never raising.
    # Returns +nil+ when it is unavailable — callers fall back to their own
    # defaults. See {Client#project_config}.
    #
    # @return [Types::ProjectConfig, nil]
    def project_config(**)
      client.project_config(**)
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

    # A synthetic pending decision for the slot — upstream's +fallbackDecision+.
    # It is not a fill, so every rendering path hides the slot, but it does not
    # assert a verdict the auction never delivered.
    def pending_decision(slot_id)
      Types::Decision.from_api("slot_id" => slot_id, "status" => "pending", "fill" => nil)
    end

    # Upstream's +fallbackBeacon+: a well-formed acknowledgement saying the
    # beacon was not accepted, so callers never have to nil-check.
    def fail_silent_beacon
      Types::BeaconResult.from_api("accepted" => false, "reason_code" => FAIL_SILENT_REASON_CODE)
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

    # A rate limit is a documented outcome, not a failure: upstream logs it at
    # +warn+ and deliberately keeps it out of +onError+, whose observers exist
    # for things that went wrong. Same posture here.
    def report_rate_limit(error)
      retry_hint = error.retry_after ? " Retry after #{error.retry_after}s." : ""
      config.logger&.warn("[wavebird] create_job was rate limited by the API.#{retry_hint}")
    end
  end
end
