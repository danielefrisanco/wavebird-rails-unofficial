# frozen_string_literal: true

require "cgi"
require "faraday"
require "json"
require "securerandom"
require "time"

require_relative "deprecation"
require_relative "errors"
require_relative "types"
require_relative "decision_normalizer"

module Wavebird
  # Low-level client for the canonical wavebird REST v1 API
  # (https://api.wavebird.ai). Ported from the original TypeScript SDK's
  # +WavebirdClient+, transposed to the API-first canonical routes the docs
  # recommend (see docs/parity.md) — the legacy +/public/wrapper/v1/*+
  # transport is intentionally not mirrored.
  #
  # Error posture (decision #003): this client raises typed {Wavebird::Error}
  # subclasses for HTTP/API/contract failures. No-fill is a first-class
  # success, never an error. The Rails-facing facade layers upstream's
  # fail-silent behavior on top. The one place this client swallows errors is
  # the {#await_decision} polling ladder, which mirrors upstream by reporting
  # each failed poll through +config.on_error+/+config.logger+ and polling on.
  #
  # The secret key is resolved immediately before every request (parity with
  # upstream +getApiKey+) and never appears in logs or inspection output.
  class Client
    # Upstream caps JSON response bodies at 64 KiB.
    MAX_JSON_BYTES = 64 * 1024

    # Canonical generation lifecycle events (upstream +GenerationEvent+).
    GENERATION_EVENTS = %w[started finished failed].freeze

    # Canonical beacon events (build prompt §3.6). Validated locally: upstream
    # maps unknown types to +null+ and falls back to the legacy wrapper beacon
    # endpoint, which this canonical-only client does not mirror — so an
    # unmapped event has nowhere to go and is rejected before the request.
    BEACON_EVENTS = %w[rendered visible clicked completed play_started play_completed heartbeat].freeze

    # Canonical consent decisions (build prompt §3.7).
    CONSENT_DECISIONS = %w[personalized basic custom].freeze

    # Canonical consent sources (build prompt §3.7).
    CONSENT_SOURCES = %w[publisher_custom server_sync wavebird_dialog].freeze

    # Input aliases for consent +source+ accepted but never emitted
    # (build prompt §3.7).
    CONSENT_SOURCE_ALIASES = { "publisher" => "publisher_custom", "custom_dialog" => "publisher_custom" }.freeze

    # +overrides.timing+ values upstream marks deprecated in +createV1JobRequest+.
    # They still work; wavebird recommends +"during"+, which requests the ad while
    # the model generates and so adds no latency to the turn.
    DEPRECATED_TIMINGS = %w[before after].freeze

    # Upstream polling constants (+getDecisionViaPolling+), all mirrored exactly.

    # Long-poll attempts made before the ladder drops to short polling.
    LONG_POLL_ATTEMPTS = 2

    # Hard cap on short-poll attempts, independent of the time budget.
    MAX_SHORT_POLL_ATTEMPTS = 120

    # Multiplier applied to the short-poll interval after each attempt.
    BACKOFF_FACTOR = 1.5

    # Ceiling the backed-off short-poll interval is clamped to, in milliseconds.
    BACKOFF_CAP_MS = 2_000

    # Random jitter added to each short-poll sleep, in milliseconds, so
    # concurrent pollers do not synchronize.
    JITTER_MS = 100

    # Name of the ActiveSupport::Notifications event published per request.
    INSTRUMENT_EVENT = "wavebird.request"

    # @return [Wavebird::Configuration]
    attr_reader :config

    # @param config [Wavebird::Configuration] defaults to the global configuration
    def initialize(config: Wavebird.configuration)
      @config = config
    end

    # Creates a job and waits for its first decision in one call —
    # +POST /v1/placements?wait_ms=+, the docs-recommended primary endpoint.
    #
    # A +nil+ placement in the response is a first-class no-fill: hide the
    # slot and continue normally.
    #
    # @param job_type [String] one of chat|code|image|voice|agent
    # @param wait_ms [Integer, nil] server-side wait for the first decision;
    #   defaults to +config.long_poll_wait_ms+, clamped to the same 0..5000 range
    # @param session_id [String, nil]
    # @param locale [String, nil] e.g. +"en-US"+; picks creatives and disclosures
    # @param slots_requested [Integer]
    # @param topic [String, nil] semantic topic hint, sent as +prompt.topic+, as
    #   in {#create_job}. A coarse subject ("cloud hosting"), never the user's
    #   message: there is deliberately no parameter for that (build prompt §4)
    # @param slot_hint [Hash, nil] defaults to +config.default_slot_hint+
    # @param overrides [Hash, nil] merged over +config.default_overrides+
    # @param publisher [Hash, nil] merged over +config.default_publisher+ into
    #   +overrides.publisher+ (parity with upstream job building)
    # @param consent [Hash, nil] per-request consent flags
    # @return [Types::PlacementResponse]
    def create_placement(job_type:, wait_ms: nil, session_id: nil, locale: nil, slots_requested: 1,
                         topic: nil, slot_hint: nil, overrides: nil, publisher: nil, consent: nil)
      wait = clamp_wait_ms(wait_ms.nil? ? config.long_poll_wait_ms : wait_ms)
      body = compact(client_id: require_client_id, session_id: session_id, job_type: job_type, locale: locale,
                     slots_requested: slots_requested, prompt: prompt_for(topic),
                     slot_hint: slot_hint || config.default_slot_hint,
                     overrides: merged_overrides(overrides, publisher), consent: consent)
      response = request(:post, "/v1/placements", body: body, query: { wait_ms: wait },
                                                  timeout_ms: config.timeout_ms + wait)
      Types::PlacementResponse.from_api(parsed_body(response) || invalid_response!("placement"))
    end

    # Creates a job without waiting for decisions — +POST /v1/jobs+
    # (advanced/compatibility route; prefer {#create_placement}).
    #
    # @param job_type [String] one of chat|code|image|voice|agent
    # @param session_id [String, nil]
    # @param locale [String, nil]
    # @param slots_requested [Integer]
    # @param topic [String, nil] semantic topic hint, sent as +prompt.topic+
    # @param slot_hint [Hash, nil] defaults to +config.default_slot_hint+, as in
    #   {#create_placement} — the engine endpoint picks between the two by
    #   delivery mode, so a configured hint must reach the auction either way
    # @param overrides [Hash, nil] merged over +config.default_overrides+
    # @param publisher [Hash, nil] merged over +config.default_publisher+
    # @param consent [Hash, nil] per-request consent flags. The canonical
    #   +/v1/jobs+ route carries consent as +overrides.gdpr_applies+ only
    #   (upstream +createV1JobRequest+ falls back to the legacy wrapper ingress
    #   for the richer flags, which this canonical-only client does not mirror).
    #   Any other flag is dropped with a warning — send it to
    #   {#create_placement}, whose request body accepts the full object.
    # @return [Types::AcceptedJob]
    def create_job(job_type:, session_id: nil, locale: nil, slots_requested: 1,
                   topic: nil, slot_hint: nil, overrides: nil, publisher: nil, consent: nil)
      body = compact(client_id: require_client_id, session_id: session_id, job_type: job_type, locale: locale,
                     slots_requested: slots_requested, prompt: prompt_for(topic),
                     slot_hint: slot_hint || config.default_slot_hint,
                     overrides: job_overrides(overrides, publisher, consent))
      accepted_job(parsed_body(request(:post, "/v1/jobs", body: body)))
    end

    # Polls a slot **once** — +GET /v1/decisions/{slot_id}?wait_ms=+, the
    # canonical endpoint wrapped 1:1.
    #
    # This is *not* the equivalent of upstream's +getDecision+; {#await_decision}
    # is. Upstream keeps its single-poll helper (+pollDecisionOnce+) private and
    # exposes only the ladder, so a caller reaching for a same-named method here
    # would silently get one request instead of the full budget. Hence the name:
    # use this only when driving your own polling loop, {#await_decision}
    # otherwise.
    #
    # @param slot_id [String]
    # @param wait_ms [Integer, nil] long-poll wait; defaults to
    #   +config.long_poll_wait_ms+; +0+ sends a plain short poll
    # @return [Types::Decision] pending, no-fill or fill
    def poll_decision_once(slot_id, wait_ms: nil)
      wait = clamp_wait_ms(wait_ms.nil? ? config.long_poll_wait_ms : wait_ms)
      response = request(:get, "/v1/decisions/#{encode(slot_id)}",
                         query: wait.positive? ? { wait_ms: wait } : nil,
                         timeout_ms: config.timeout_ms + wait)
      DecisionNormalizer.call(parsed_body(response))
    end

    # Polls a slot until its decision is ready, mirroring the upstream polling
    # ladder and budgets exactly: 2 long-poll attempts, then short polls with
    # exponential backoff (x1.5, capped at 2s, 0-99ms jitter) up to
    # min(120, decision_timeout_ms / short_poll_interval_ms) attempts.
    #
    # Failed polls are reported through +config.on_error+/+config.logger+ and
    # polling continues (upstream behavior). When the budget is exhausted this
    # raises {DecisionTimeoutError} (upstream returns a pending fallback; the
    # fail-silent facade restores that behavior — decision #003).
    #
    # @param slot_id [String]
    # @return [Types::Decision] a ready decision (fill or no-fill)
    # @raise [DecisionTimeoutError] when the polling budget is exhausted
    def await_decision(slot_id)
      LONG_POLL_ATTEMPTS.times do
        found = poll_quietly(slot_id, config.long_poll_wait_ms)
        return found if found
      end
      short_poll(slot_id) || decision_timeout!(slot_id)
    end

    # Records a delivery beacon — +POST /v1/beacons+. Advanced escape hatch
    # for custom/server-rendered flows: the hosted renderer already sends
    # beacons itself, do not duplicate them.
    #
    # @param slot_id [String]
    # @param asset_token [String] sensitive proof material from the decision
    # @param event [String] one of rendered|visible|clicked|completed|
    #   play_started|play_completed|heartbeat
    # @param beacon_id [String] idempotency key; auto-generated by default
    # @param occurred_at [Time, String, nil] defaults to now — the API rejects
    #   stale timestamps (+BEACON_TOO_LATE+), so omit it unless replaying
    # @param metadata [Hash, nil]
    # @return [Types::BeaconResult] 204/empty responses count as accepted
    # @raise [ArgumentError] for an event outside {BEACON_EVENTS}, raised before
    #   the request so no asset token reaches the wire on a typo
    def record_beacon(slot_id:, asset_token:, event:, beacon_id: SecureRandom.uuid, occurred_at: nil, metadata: nil)
      event = validate_enum!(event, BEACON_EVENTS, "event")
      body = compact(beacon_id: beacon_id, slot_id: slot_id, asset_token: asset_token, event: event,
                     occurred_at: iso8601(occurred_at || Time.now), metadata: metadata)
      data = parsed_body(request(:post, "/v1/beacons", body: body))
      Types::BeaconResult.from_api(data || { "accepted" => true, "reason_code" => "OK" })
    end

    # Reports a generation lifecycle event — +POST /v1/jobs/{job_id}/generation/{event}+
    # (decision #002).
    #
    # @param job_id [String]
    # @param event [String, Symbol] one of started|finished|failed
    # @param generation_id [String, nil]
    # @param model_id [String, nil]
    # @param usage_json [Object, nil]
    # @param error [String, nil]
    # @return [true]
    # @raise [ArgumentError] for an unknown event (it forms the URL path)
    # rubocop:disable Naming/PredicateMethod -- +true+ is a fire-and-forget ack, not a predicate
    def report_generation(job_id, event, generation_id: nil, model_id: nil, usage_json: nil, error: nil)
      event = validate_enum!(event, GENERATION_EVENTS, "event")
      body = compact(generation_id: generation_id, model_id: model_id, usage_json: usage_json, error: error)
      request(:post, "/v1/jobs/#{encode(job_id)}/generation/#{event}", body: body)
      true
    end
    # rubocop:enable Naming/PredicateMethod

    # Syncs session/user-level consent — +POST /v1/consent+ (optional; the
    # per-request +consent+ object in {#create_placement} does not depend on it).
    #
    # @param decision [String] one of personalized|basic|custom
    # @param source [String] one of publisher_custom|server_sync|wavebird_dialog;
    #   input aliases +publisher+/+custom_dialog+ are accepted and canonicalized
    # @param purposes [Hash, nil]
    # @param session_id [String, nil]
    # @return [Types::ConsentState]
    # @raise [ArgumentError] for a decision or source outside the canonical enums
    def record_consent(decision:, source:, purposes: nil, session_id: nil)
      decision = validate_enum!(decision, CONSENT_DECISIONS, "decision")
      source = validate_enum!(CONSENT_SOURCE_ALIASES.fetch(source.to_s, source), CONSENT_SOURCES, "source")
      body = compact(client_id: require_client_id, session_id: session_id, decision: decision,
                     source: source, purposes: purposes)
      Types::ConsentState.from_api(parsed_body(request(:post, "/v1/consent", body: body)) || {})
    end

    # Exchanges the publishable key + +Origin+ for a short-lived browser
    # activation token — +POST /v1/browser/activate+ (secondary; Script Tag /
    # pure-browser pattern only). Sent without the secret key, like upstream.
    #
    # @param origin [String] the browser origin the token is scoped to
    # @param publishable_key [String, #call] defaults to +config.publishable_key+
    # @return [Types::BrowserActivation]
    def activate_browser(origin:, publishable_key: config.publishable_key)
      key = publishable_key.respond_to?(:call) ? publishable_key.call : publishable_key
      raise ConfigurationError, "Wavebird publishable_key is not configured" if blank?(key)

      response = request(:post, "/v1/browser/activate", body: { publishable_key: key.strip },
                                                        headers: { "Origin" => origin }, auth: false)
      browser_activation(parsed_body(response))
    end

    # Fetches the non-secret runtime project configuration —
    # +GET /v1/projects/{client_id}/config+.
    #
    # @param client_id [String] defaults to +config.client_id+
    # @return [Types::ProjectConfig]
    def project_config(client_id: config.client_id)
      raise ConfigurationError, "Wavebird client_id is not configured" if blank?(client_id)

      Types::ProjectConfig.from_api(parsed_body(request(:get, "/v1/projects/#{encode(client_id)}/config")) || {})
    end

    private

    # -- polling ladder ------------------------------------------------------

    def short_poll(slot_id)
      max_attempts = [MAX_SHORT_POLL_ATTEMPTS, (config.decision_timeout_ms.to_f / config.short_poll_interval_ms).ceil]
                     .min
      max_attempts.times do |attempt|
        found = poll_quietly(slot_id, 0)
        return found if found

        sleep_backoff(attempt) if attempt + 1 < max_attempts
      end
      nil
    end

    # One poll of the ladder: ready decisions win; pending decisions and
    # failed polls (reported, then swallowed — upstream behavior) both
    # continue the ladder.
    def poll_quietly(slot_id, wait_ms)
      found = poll_decision_once(slot_id, wait_ms: wait_ms)
      found.ready? ? found : nil
    rescue Error => e
      report_swallowed_error(e)
      nil
    end

    def sleep_backoff(attempt)
      backoff_ms = [config.short_poll_interval_ms * (BACKOFF_FACTOR**attempt), BACKOFF_CAP_MS].min
      sleep_ms(backoff_ms + rand(JITTER_MS))
    end

    def sleep_ms(milliseconds)
      sleep(milliseconds / 1000.0)
    end

    # Builds the +prompt+ object, passing +topic+ through
    # +config.before_send_text+ on the way. Returns nil when there is nothing to
    # send, so +compact+ drops the key entirely rather than sending an empty
    # object.
    def prompt_for(topic)
      return nil if topic.nil?

      text = filter_outbound_text(topic)
      text.nil? ? nil : { topic: text }
    end

    # Applies +config.before_send_text+ to one caller-supplied value.
    #
    # Fails **closed**: a raising filter drops the value instead of sending it,
    # because a broken filter must never leak the text it was installed to
    # catch. Reported every time rather than once — a persistently broken filter
    # degrades every auction silently, so the noise is the point.
    def filter_outbound_text(value)
      hook = config.before_send_text
      return value if hook.nil?

      hook.call(value)
    rescue StandardError => e
      report_swallowed_error(e)
      nil
    end

    def report_swallowed_error(error)
      begin
        config.on_error&.call(error)
      rescue StandardError
        nil # observers must not break the ladder (upstream behavior)
      end
      # detailed_message, not message: the API's `message` is often a generic
      # "check the request body schema" while reason_code/hint/fields name the
      # actual cause. A log line that omits them sends the reader guessing.
      described = error.is_a?(Error) ? error.diagnostic_message : error.message
      config.logger&.warn("[wavebird] #{error.class}: #{described}")
    end

    # -- request plumbing ----------------------------------------------------

    def request(method, path, body: nil, query: nil, headers: {}, timeout_ms: config.timeout_ms, auth: true)
      # The payload carries only non-sensitive routing/outcome fields: never the
      # request body, query, headers, secret_key or asset_token (build prompt
      # §4). +status+/+error+ are filled in as the request resolves.
      instrument(method: method.to_s, path: path) do |payload|
        response = run_request(method, path, body: body, query: query, headers: headers,
                                             timeout_ms: timeout_ms, auth: auth)
        payload[:status] = response.status
        raise_for_status(response, path)
        response
      end
    end

    def run_request(method, path, body:, query:, headers:, timeout_ms:, auth:)
      connection.run_request(method, config.api_base_url + path,
                             body && JSON.generate(body),
                             request_headers(headers, body: body, auth: auth)) do |req|
        req.params.update(query) if query
        req.options.timeout = timeout_ms / 1000.0
      end
    rescue Faraday::TimeoutError
      raise TimeoutError, "Request to #{path} timed out after #{timeout_ms}ms"
    rescue Faraday::ConnectionFailed, Faraday::SSLError => e
      # Adapters report connect-phase timeouts as ConnectionFailed wrapping a
      # Timeout::Error (net_http raises Net::OpenTimeout), so the cause decides:
      # upstream treats any timed-out request as a timeout, not a connect error.
      raise TimeoutError, "Request to #{path} timed out after #{timeout_ms}ms" if timeout_cause?(e)

      raise ConnectionError, "Request to #{path} failed: #{e.message}"
    end

    # Publishes +wavebird.request+ when ActiveSupport::Notifications is present,
    # tagging the payload with the raised error class on failure. Degrades to a
    # plain yield outside Rails so the client works without ActiveSupport.
    def instrument(payload)
      return yield(payload) unless notifications_available?

      ActiveSupport::Notifications.instrument(INSTRUMENT_EVENT, payload) do
        yield payload
      rescue Error => e
        payload[:error] = e.class.name
        raise
      end
    end

    def notifications_available?
      !defined?(ActiveSupport::Notifications).nil?
    end

    # @return [Boolean] the transport error was caused by a timeout
    def timeout_cause?(error)
      cause = error.wrapped_exception || error.cause
      cause.is_a?(Timeout::Error) || cause.is_a?(Errno::ETIMEDOUT)
    end

    def connection
      @connection ||= Faraday.new
    end

    def request_headers(extra, body:, auth:)
      headers = {
        "accept" => "application/json",
        "user-agent" => config.wrapper_version,
        "x-csl-wrapper-version" => config.wrapper_version
      }
      headers["authorization"] = "Bearer #{require_secret_key}" if auth
      headers["content-type"] = "application/json" unless body.nil?
      headers.merge(extra)
    end

    def raise_for_status(response, path)
      status = response.status
      return if (200..299).cover?(status)

      enforce_size_cap!(response.body)
      envelope = safe_parse_hash(response.body)
      raise error_for(status, path, envelope, response.headers)
    end

    def error_for(status, path, envelope, headers)
      code = envelope["error"]
      klass = Error.class_for(code)
      klass = RateLimitedError if status == 429 && klass == APIError
      message = envelope["message"] || "HTTP request to #{path} failed with status #{status}."
      options = { code: code, request_id: envelope["request_id"] || headers["x-request-id"],
                  docs_url: envelope["docs_url"], http_status: status,
                  # Undocumented but frequently the only actionable part of the
                  # response: `message` is often a generic "check the request
                  # body schema" while `reason_code` names the actual cause.
                  reason_code: envelope["reason_code"], hint: envelope["hint"],
                  expected_shape: envelope["expected_shape"],
                  fields: envelope["fields"].is_a?(Array) ? envelope["fields"] : nil }
      options[:retry_after] = parse_retry_after(headers["retry-after"]) if klass == RateLimitedError
      klass.new(message, **options)
    end

    # Port of upstream +parseRetryAfterMs+ in seconds: non-negative
    # delta-seconds, else an HTTP date, else the 1-second default.
    def parse_retry_after(raw)
      raw = raw.to_s.strip
      return 1.0 if raw.empty?

      seconds = Float(raw, exception: false)
      return seconds if seconds&.finite? && seconds >= 0

      [Time.parse(raw) - Time.now, 0.0].max
    rescue ArgumentError
      1.0
    end

    # -- response handling ---------------------------------------------------

    def parsed_body(response)
      body = response.body
      return nil if body.nil? || body.empty?

      enforce_size_cap!(body)
      JSON.parse(body)
    rescue JSON::ParserError
      raise InvalidResponseError.new("Response could not be parsed as JSON", code: "parse_error")
    end

    # Upstream enforces the cap mid-stream, in the response's own +data+ handler
    # (+wavebird-client.ts:740+), so it trips before the client knows whether it
    # is holding a success body or an error envelope: an oversized 4xx/5xx is
    # destroyed exactly like an oversized 200. That is why this guard runs on
    # both paths, and why it wins over +error_for+ -- upstream rejects the whole
    # request there, losing the status classification (and a 429's +Retry-After+)
    # with it, rather than reporting an HTTP error it could not read.
    def enforce_size_cap!(body)
      return if body.to_s.bytesize <= MAX_JSON_BYTES

      raise InvalidResponseError.new("Response body exceeds #{MAX_JSON_BYTES} bytes", code: "response_too_large")
    end

    def safe_parse_hash(body)
      parsed = body.nil? || body.empty? ? nil : JSON.parse(body)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    # Port of upstream +normalizeV1JobResponse+ validation.
    def accepted_job(data)
      job_id = data.is_a?(Hash) ? presence(Types.field(data, :job_id)) : nil
      slot_ids = data.is_a?(Hash) ? Types.field(data, :slot_ids) : nil
      valid_slots = slot_ids.is_a?(Array) && !slot_ids.empty? && slot_ids.all? { |id| presence(id) }
      invalid_response!("job") unless job_id && valid_slots && Types.field(data, :status) == "accepted"

      Types::AcceptedJob.from_api(data)
    end

    # Port of upstream activation response validation (browser-client.ts).
    def browser_activation(data)
      token = data.is_a?(Hash) ? presence(Types.field(data, :activation_token)) : nil
      expires = data.is_a?(Hash) ? Types.field(data, :expires_at_ms) : nil
      invalid_response!("activation") unless token && expires.is_a?(Numeric) && expires.to_f.finite?

      Types::BrowserActivation.from_api(data)
    end

    # -- request building ----------------------------------------------------

    # Overrides for the canonical +POST /v1/jobs+ body. Port of upstream
    # +createV1JobRequest+: the canonical route expresses consent as
    # +overrides.gdpr_applies+ and nothing else, so that one flag is folded in
    # and any other is reported rather than silently dropped (upstream reaches
    # the legacy wrapper ingress for those; this client is canonical-only).
    def job_overrides(overrides, publisher, consent)
      merged = merged_overrides(overrides, publisher)
      return merged if consent.nil?

      warn_unmapped_consent(consent)
      gdpr_applies = Types.field(consent, :gdpr_applies)
      return merged if gdpr_applies.nil?

      (merged || {}).merge(gdpr_applies: gdpr_applies)
    end

    # Names the consent flags the canonical jobs route cannot carry, so a caller
    # who set them learns they need {#create_placement} instead of discovering
    # it from an auction that ignored their flags.
    def warn_unmapped_consent(consent)
      dropped = consent.keys.map(&:to_s) - ["gdpr_applies"]
      return if dropped.empty?

      config.logger&.warn(
        "[wavebird] POST /v1/jobs carries consent as gdpr_applies only; ignoring #{dropped.sort.join(', ')}. " \
        "Use create_placement (POST /v1/placements) to send the full consent object."
      )
    end

    def merged_overrides(overrides, publisher)
      merged_publisher = merge_hashes(config.default_publisher, publisher)
      merged = merge_hashes(config.default_overrides, overrides) || {}
      warn_deprecated_timing(Types.field(merged, :timing))
      merged = merged.merge(publisher: merged_publisher) if merged_publisher
      merged.empty? ? nil : merged
    end

    # Port of upstream's stage-3 timing deprecation (+createV1JobRequest+). The
    # value is still sent — only wavebird decides what it means — but a host
    # asking for the legacy timing hears about the recommended one once per
    # process. Checked on the *merged* overrides, so a timing set once in
    # +config.default_overrides+ is caught as readily as a per-call one, and both
    # endpoint methods are covered.
    #
    # This matters more than it looks: wavebird's own sandbox site generates an
    # example request carrying +"timing": "before"+, so a host that copy-pastes
    # it would otherwise never learn the value is deprecated.
    def warn_deprecated_timing(timing)
      return unless DEPRECATED_TIMINGS.include?(timing.to_s)

      Deprecation.warn_once(
        "stage3Timing:#{timing}",
        "Using '#{timing}' timing. wavebird's recommended timing is 'during' for zero-latency ads.",
        config.logger
      )
    end

    def merge_hashes(base, extra)
      return nil if base.nil? && extra.nil?

      (base || {}).merge(extra || {})
    end

    def compact(hash)
      hash.compact
    end

    # Rejects values outside a canonical enum before the request is built, so a
    # typo fails fast locally instead of round-tripping (and, for beacons,
    # without putting an asset token on the wire).
    #
    # @return [String] the value as a canonical string
    def validate_enum!(value, allowed, name)
      canonical = value.to_s
      return canonical if allowed.include?(canonical)

      raise ArgumentError, "#{name} must be one of #{allowed.join('|')}, got #{value.inspect}"
    end

    # +wait_ms+ shares the long-poll clamp range (0..5000) from upstream.
    def clamp_wait_ms(value)
      unless value.is_a?(Numeric) && value.to_f.finite?
        raise ArgumentError, "wait_ms must be a number, got #{value.inspect}"
      end

      value.floor.clamp(0, 5_000)
    end

    def iso8601(value)
      value.respond_to?(:getutc) ? value.getutc.iso8601(3) : value
    end

    def encode(value)
      CGI.escapeURIComponent(value.to_s)
    end

    def presence(value)
      value.is_a?(String) && !value.strip.empty? ? value : nil
    end

    def require_secret_key
      key = config.resolved_secret_key
      raise ConfigurationError, "Wavebird secret_key is not configured" if blank?(key)

      key
    end

    def require_client_id
      raise ConfigurationError, "Wavebird client_id is not configured" if blank?(config.client_id)

      config.client_id
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def invalid_response!(kind)
      raise InvalidResponseError.new("Invalid #{kind} response", code: "invalid_#{kind}_response")
    end

    def decision_timeout!(slot_id)
      raise DecisionTimeoutError.new(
        "Decision polling exceeded the configured budget of #{config.decision_timeout_ms}ms for slot #{slot_id}",
        code: "decision_timeout"
      )
    end
  end
end
