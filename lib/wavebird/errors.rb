# frozen_string_literal: true

module Wavebird
  # Base class for all wavebird-rails errors.
  #
  # Carries the API error envelope fields (docs: /api/reference/errors):
  # +code+ (lowercase machine code), +request_id+ (also echoed in the
  # X-Request-Id header — include it in support requests), +docs_url+, and the
  # HTTP +http_status+ when the error came from an HTTP response.
  #
  # It also carries the API's **diagnostic** fields, which are the ones that
  # actually tell you what to change: {#reason_code}, {#hint},
  # {#expected_shape} and {#fields}. These are not in the documented envelope
  # and were found empirically — a 400 whose +message+ said only "Request
  # validation failed. Check the request body schema" also carried
  # +reason_code: "e01_request_authority_malformed_bidfloor"+, which named the
  # problem exactly. Discarding them cost a long afternoon of guessing against a
  # sandbox, so everything the envelope sends is kept.
  #
  # Error posture (decision #003): the low-level {Wavebird::Client} raises
  # these typed errors; the Rails-facing layer is fail-silent like the
  # original TypeScript SDK and reports through +config.on_error+ instead.
  class Error < StandardError
    attr_reader :code, :request_id, :docs_url, :http_status, :reason_code, :hint, :expected_shape, :fields

    # @param message [String] human-readable message
    # @param code [String, nil] lowercase API error code (e.g. "unauthorized")
    # @param request_id [String, nil] request id for support/debugging
    # @param docs_url [String, nil] documentation link from the error envelope
    # @param http_status [Integer, nil] HTTP status of the failed response
    # @param reason_code [String, nil] machine-readable cause, far more specific
    #   than +code+ (e.g. +"e01_request_authority_malformed_bidfloor"+)
    # @param hint [String, nil] the API's own remediation sentence
    # @param expected_shape [String, nil] request-shape identifier
    #   (e.g. +"flat_server_api_v1"+)
    # @param fields [Array<Hash>, nil] per-field validation failures, each with
    #   +path+, +message+ and +expected+
    def initialize(message = nil, code: nil, request_id: nil, docs_url: nil, http_status: nil,
                   reason_code: nil, hint: nil, expected_shape: nil, fields: nil)
      super(message)
      @code = code
      @request_id = request_id
      @docs_url = docs_url
      @http_status = http_status
      @reason_code = reason_code
      @hint = hint
      @expected_shape = expected_shape
      @fields = fields
    end

    # The message plus whatever diagnostics the API sent, for a log line or an
    # +on_error+ report. +message+ alone is frequently generic — this is the
    # form worth putting in front of a human.
    #
    # **Deliberately not called +detailed_message+.** Ruby 3.2+ defines
    # +Exception#detailed_message(highlight:)+ and calls it when printing an
    # uncaught exception. Overriding it with a zero-arity method raises
    # +ArgumentError+ *while Ruby is rendering the error*, replacing the real
    # failure with a confusing one — verified on 3.4.10 before this was renamed.
    #
    # @return [String]
    def diagnostic_message
      labelled = { reason_code: reason_code, hint: hint, expected_shape: expected_shape }
                 .filter_map { |name, value| "#{name}=#{value}" if value }

      [message, *labelled, *described_fields].join(" | ")
    end

    private

    # Each per-field failure as one readable clause. Entries carrying nothing
    # useful are dropped rather than rendered as an empty "field ".
    def described_fields
      Array(fields).filter_map do |field|
        next unless field.respond_to?(:[])

        described = [field["path"], field["message"], field["expected"]].compact.join(": ")
        "field #{described}" unless described.empty?
      end
    end
  end

  # Configuration is missing or invalid (e.g. blank secret key at first use).
  class ConfigurationError < Error; end

  # The HTTP request could not be performed (DNS, refused, TLS, ...).
  class ConnectionError < Error; end

  # The HTTP request timed out.
  class TimeoutError < ConnectionError; end

  # The response violated the API contract (invalid JSON, oversized body, or a
  # decision/job payload failing the normalization rules ported from the
  # upstream SDK's +sdk_invalid_*_response+ / parse errors).
  class InvalidResponseError < Error; end

  # {Client#await_decision} exhausted the +decision_timeout_ms+ polling budget
  # (upstream +sdk_decision_timeout+). Upstream reports the error and returns a
  # *pending* fallback (+status: "pending"+, +fill: nil+); the raise-y low-level
  # client raises instead, per decision #003, and the fail-silent facade catches
  # it and returns that same pending fallback (decision #018).
  class DecisionTimeoutError < Error; end

  # API returned an error envelope with an unrecognized code (fallback class).
  class APIError < Error; end

  # 401 +unauthorized+ — add valid credentials.
  class UnauthorizedError < APIError; end

  # 403 +forbidden+ — wrong key type or origin for this endpoint.
  class ForbiddenError < APIError; end

  # 429 +rate_limited+ — back off using {#retry_after}.
  class RateLimitedError < APIError
    # Seconds to wait before retrying, parsed from the Retry-After header.
    attr_reader :retry_after

    # @param retry_after [Numeric, nil] seconds from the Retry-After header
    def initialize(message = nil, retry_after: nil, **envelope)
      super(message, **envelope)
      @retry_after = retry_after
    end
  end

  # 400 +validation_error+ — fix the request body shape (message includes field paths).
  class ValidationError < APIError; end

  # 404 +not_found+ — resource missing or outside the authenticated scope.
  class NotFoundError < APIError; end

  # Reopened after the subclasses exist to register the code→class mapping.
  class Error
    # Lowercase API error codes mapped to their exception classes.
    CODE_CLASSES = {
      "unauthorized" => UnauthorizedError,
      "forbidden" => ForbiddenError,
      "rate_limited" => RateLimitedError,
      "validation_error" => ValidationError,
      "not_found" => NotFoundError
    }.freeze

    # Resolves the exception class for an API error code.
    #
    # @param code [String, nil] lowercase code from the error envelope
    # @return [Class] a subclass of {APIError}; {APIError} itself for unknown codes
    def self.class_for(code)
      CODE_CLASSES.fetch(code, APIError)
    end
  end
end
