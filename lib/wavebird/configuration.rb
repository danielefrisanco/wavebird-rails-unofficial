# frozen_string_literal: true

require "uri"
require_relative "errors"
require_relative "version"

module Wavebird
  # Gem-wide configuration, set via {Wavebird.configure}.
  #
  # Numeric option defaults and clamping ranges mirror the original TypeScript
  # SDK's +WavebirdClientOptions+ (see docs/parity.md): out-of-range numeric
  # values are clamped, +nil+ resolves to the default. Unlike the TS SDK
  # (where the compiler rejects non-numbers), non-numeric values raise
  # {ConfigurationError} — the Ruby analog of a type error.
  class Configuration
    # Canonical wavebird REST v1 origin, used unless {#api_base_url=} overrides it.
    DEFAULT_API_BASE_URL = "https://api.wavebird.ai"

    # Hostnames allowed to use plain HTTP (mirrors upstream LOCALHOST_HOSTNAMES).
    LOCALHOST_HOSTNAMES = ["localhost", "127.0.0.1", "::1", "[::1]"].freeze

    # name => [min, max, default] — mirrors upstream clampInt call sites.
    NUMERIC_OPTIONS = {
      timeout_ms: [250, 30_000, 2_000],
      decision_timeout_ms: [1_000, 60_000, 30_000],
      long_poll_wait_ms: [0, 5_000, 1_500],
      short_poll_interval_ms: [100, 5_000, 250]
    }.freeze

    # @return [String, #call] the server secret key (sk_test_/sk_dry_/sk_live_),
    #   or a callable returning it immediately before each request (parity with
    #   upstream +getApiKey+). Never expose to browsers or asset bundles.
    attr_accessor :secret_key

    # @return [String, nil] the wavebird project client id (wbproj_...)
    attr_accessor :client_id

    # @return [String, #call, nil] publishable browser key (pk_...) used only
    #   by {Client#activate_browser} (Script Tag / browser flows, secondary);
    #   safe for browsers by design, unlike +secret_key+
    attr_accessor :publishable_key

    # @return [Hash, nil] default +slot_hint+ merged into placement requests
    attr_accessor :default_slot_hint

    # @return [Hash, nil] default +overrides+ merged into placement requests
    attr_accessor :default_overrides

    # @return [Hash, nil] publisher metadata merged into every job unless
    #   overridden per call (parity with upstream +publisher+ option)
    attr_accessor :default_publisher

    # Consent flags sent by {SponsorSlotsController}, which does not accept them
    # from the browser — a page must not be able to assert consent on a user's
    # behalf. Defaults to +nil+: like the upstream SDK, the gem sends no consent
    # object unless you supply one (decision #013). Hosts with a CMP set it here,
    # e.g. +{ semantic_targeting: false, prompt_shared: false,
    # consent_source: "publisher_custom" }+.
    #
    # @return [Hash, nil]
    attr_accessor :default_consent

    # @return [#call, nil] observer invoked with a {Wavebird::Error} for
    #   failures swallowed by the fail-silent Rails-facing layer (parity with
    #   upstream +onError+)
    attr_accessor :on_error

    # A hook for filtering caller-supplied free text before it is sent to
    # wavebird — a redaction/scrubbing seam that needs no monkey-patching, and
    # the only way to filter the engine endpoint, whose caller is
    # {SponsorSlotsController} inside this gem.
    #
    # Receives **one value at a time**, and only values a caller supplied as
    # free text — today that is +topic:+ on {Client#create_placement} and
    # {Client#create_job}. It is never handed +secret_key+, +client_id+,
    # +consent+, +overrides+ or any structural part of the request. That is
    # deliberate: a hook given the whole body could rewrite the credentials,
    # drop the consent object, or inject the response-only fields this gem
    # refuses to send. Handed one string, it structurally cannot.
    #
    # Return the replacement string, or +nil+ to drop the field entirely.
    #
    #   config.before_send_text = ->(text) { MyScrubber.clean(text) }
    #
    # **Fails closed.** If the callable raises, the field is **dropped** rather
    # than sent — a broken filter must never leak the value it was installed to
    # catch. The failure is logged at +warn+ and reported through {#on_error}
    # every time it happens, not once, because a persistently broken filter
    # silently degrades every auction and should stay noisy.
    #
    # Unset (the default) means values are sent unchanged.
    #
    # @return [#call, nil]
    attr_accessor :before_send_text

    # The consent object wavebird's hosted renderer requires before it will run
    # a turn. **Without this, no ad is ever requested** — the renderer refuses
    # every turn silently, with no request and no error.
    #
    # Set a callable; it is resolved fresh on every slot render, so the gem never
    # stores consent and a visitor's answer can change between turns:
    #
    #   config.authoritative_consent = lambda do
    #     record = MyConsentStore.for(Current.session)
    #     { lifecycle_state: record.granted? ? "granted" : "denied",
    #       expires_at_ms: record.expires_at.to_i * 1000 }
    #   end
    #
    # Only +lifecycle_state+ and +expires_at_ms+ are required. +revision+
    # (default +1+) and +updated_at_ms+ (default: now) are bookkeeping the
    # renderer checks but does not interpret, and are filled in when omitted.
    # The two required fields are never defaulted: they are the assertion
    # itself, and inventing them would claim a consent nobody gave.
    #
    # A state other than +"granted"+ is a normal answer — the slot stays empty.
    # A malformed object is reported through {#logger}, because the renderer
    # would otherwise reject it in silence.
    #
    # @return [#call, Hash, nil]
    # @see AuthoritativeConsent
    attr_accessor :authoritative_consent

    # @return [Logger, nil] logger for diagnostics; all logging redacts
    #   +secret_key+ and +asset_token+
    attr_accessor :logger

    # @return [String] value for the x-csl-wrapper-version request header
    attr_accessor :wrapper_version

    # @return [String, Symbol] ActiveJob queue for {DecisionPollJob} (async
    #   delivery mode); defaults to +:default+
    attr_accessor :async_queue_name

    # @return [String] API base URL, HTTPS-only except localhost
    attr_reader :api_base_url

    def initialize
      @secret_key = nil
      @client_id = nil
      @publishable_key = nil
      @api_base_url = DEFAULT_API_BASE_URL
      @default_slot_hint = nil
      @default_overrides = nil
      @default_publisher = nil
      @default_consent = nil
      @on_error = nil
      @logger = nil
      @wrapper_version = "wavebird-rails/#{VERSION}"
      @async_queue_name = :default
      NUMERIC_OPTIONS.each { |name, (_, _, default)| instance_variable_set(:"@#{name}", default) }
    end

    NUMERIC_OPTIONS.each do |name, (min, max, default)|
      # @return [Integer] milliseconds, clamped to the upstream range
      attr_reader name

      define_method(:"#{name}=") do |value|
        instance_variable_set(:"@#{name}", clamp_int(name, value, min, max, default))
      end
    end

    # Sets and normalizes the API base URL.
    #
    # Mirrors upstream +normalizeBaseUrl+: only http/https accepted, remote
    # targets must use HTTPS (plain HTTP is allowed for localhost only), and
    # any trailing slash is stripped.
    #
    # @param value [String]
    # @raise [ConfigurationError] when the URL is invalid or insecure
    def api_base_url=(value)
      uri = parse_http_uri(value)
      unless uri.scheme == "https" || LOCALHOST_HOSTNAMES.include?(uri.host)
        raise ConfigurationError, "api_base_url must use HTTPS (plain HTTP is allowed for localhost only): #{value}"
      end

      @api_base_url = value.to_s.sub(%r{/+\z}, "")
    end

    # Resolves the secret key, calling it if configured as a callable.
    #
    # @return [String, nil]
    def resolved_secret_key
      secret_key.respond_to?(:call) ? secret_key.call : secret_key
    end

    # Ensures the configuration is usable for API calls.
    #
    # @raise [ConfigurationError] when the secret key or client id is blank
    # @return [self]
    def validate!
      key = resolved_secret_key
      raise ConfigurationError, "Wavebird secret_key is not configured" if key.nil? || key.to_s.strip.empty?
      raise ConfigurationError, "Wavebird client_id is not configured" if client_id.nil? || client_id.strip.empty?

      self
    end

    # @return [String] inspection string with the secret key redacted
    def inspect
      "#<#{self.class.name} client_id=#{client_id.inspect} api_base_url=#{api_base_url.inspect} " \
        "secret_key=#{secret_key.nil? ? 'nil' : '[REDACTED]'}>"
    end
    alias to_s inspect

    private

    # Ports upstream +clampInt+: numeric → floored and clamped; nil → default.
    def clamp_int(name, value, min, max, default)
      return default if value.nil?
      unless value.is_a?(Numeric) && value.to_f.finite?
        raise ConfigurationError, "#{name} must be a number or nil, got #{value.inspect}"
      end

      value.floor.clamp(min, max)
    end

    def parse_http_uri(value)
      uri = URI.parse(value.to_s)
      raise ConfigurationError, "api_base_url must be an http(s) URL, got #{value.inspect}" unless
        uri.is_a?(URI::HTTP) && !uri.host.nil?

      uri
    rescue URI::InvalidURIError
      raise ConfigurationError, "api_base_url is not a valid URL: #{value.inspect}"
    end
  end
end
