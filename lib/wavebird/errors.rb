# frozen_string_literal: true

module Wavebird
  # Base class for all wavebird-rails errors.
  #
  # Carries the API error envelope fields (docs: /api/reference/errors):
  # +code+ (lowercase machine code), +request_id+ (also echoed in the
  # X-Request-Id header — include it in support requests), +docs_url+, and the
  # HTTP +http_status+ when the error came from an HTTP response.
  #
  # Error posture (decision #003): the low-level {Wavebird::Client} raises
  # these typed errors; the Rails-facing layer is fail-silent like the
  # original TypeScript SDK and reports through +config.on_error+ instead.
  class Error < StandardError
    attr_reader :code, :request_id, :docs_url, :http_status

    # @param message [String] human-readable message
    # @param code [String, nil] lowercase API error code (e.g. "unauthorized")
    # @param request_id [String, nil] request id for support/debugging
    # @param docs_url [String, nil] documentation link from the error envelope
    # @param http_status [Integer, nil] HTTP status of the failed response
    def initialize(message = nil, code: nil, request_id: nil, docs_url: nil, http_status: nil)
      super(message)
      @code = code
      @request_id = request_id
      @docs_url = docs_url
      @http_status = http_status
    end
  end

  # Configuration is missing or invalid (e.g. blank secret key at first use).
  class ConfigurationError < Error; end

  # The HTTP request could not be performed (DNS, refused, TLS, ...).
  class ConnectionError < Error; end

  # The HTTP request timed out.
  class TimeoutError < ConnectionError; end

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
