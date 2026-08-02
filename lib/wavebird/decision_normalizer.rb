# frozen_string_literal: true

require_relative "errors"
require_relative "types"

module Wavebird
  # Normalizes and validates the canonical +GET /v1/decisions/{slot_id}+
  # response into a {Types::Decision}. Direct port of the upstream SDK's
  # +normalizeV1Decision+ (wavebird-client.ts), including its validation rules:
  #
  # - +status:"pending"+ with +decision:null+ is a pending result;
  # - a ready no-fill requires +reason+, +no_fill_reason+ and +cs_declaration+;
  # - a ready fill requires +format+ in banner|clip|native, +asset_token+,
  #   +cs_declaration+, +constraints+, and +dimensions+ present (null allowed);
  #   native fills require +assets+ (title + image_url), non-native fills
  #   require +delivery_url+;
  # - missing creative numbers fall back to upstream defaults (300x250, 3s).
  #
  # Malformed responses raise {InvalidResponseError} (upstream throws
  # +sdk_invalid_decision_response+; the polling ladder treats it as a failed
  # poll, mirroring upstream's fail-silent fallback).
  module DecisionNormalizer
    # Creative duration used when the decision omits +duration_ms+ (upstream default).
    DEFAULT_CREATIVE_DURATION_MS = 3_000

    # Creative width used when +dimensions+ is null or omits +width+.
    DEFAULT_CREATIVE_WIDTH = 300

    # Creative height used when +dimensions+ is null or omits +height+.
    DEFAULT_CREATIVE_HEIGHT = 250

    # Canonical creative formats a ready fill may declare.
    FORMATS = %w[banner clip native].freeze

    module_function

    # @param body [Object] parsed response body of +GET /v1/decisions/{slot_id}+
    # @return [Types::Decision]
    # @raise [InvalidResponseError] when the body violates the contract
    def call(body)
      invalid! unless body.is_a?(Hash)
      slot_id = read_string(Types.field(body, :slot_id)) || invalid!
      status = Types.field(body, :status)
      decision = Types.field(body, :decision)
      return pending_decision(slot_id, body) if status == "pending" && decision.nil?

      fill = decision.is_a?(Hash) ? Types.field(decision, :fill) : nil
      invalid! unless status == "ready" && [true, false].include?(fill)
      fill ? fill_decision(slot_id, decision) : no_fill_decision(slot_id, decision)
    end

    # @api private
    def pending_decision(slot_id, body)
      Types::Decision.from_api(
        "slot_id" => slot_id, "status" => "pending", "fill" => nil,
        **metadata_field(body)
      )
    end

    # @api private
    def no_fill_decision(slot_id, decision)
      reason = read_string(Types.field(decision, :reason)) || invalid!
      no_fill_reason = read_string(Types.field(decision, :no_fill_reason)) || invalid!
      cs_declaration = read_string(Types.field(decision, :cs_declaration)) || invalid!
      Types::Decision.from_api(
        "slot_id" => slot_id, "status" => "ready", "fill" => false,
        "reason" => reason, "no_fill_reason" => no_fill_reason, "cs_declaration" => cs_declaration,
        **metadata_field(decision)
      )
    end

    # @api private
    def fill_decision(slot_id, decision)
      format = FORMATS.include?(Types.field(decision, :format)) ? Types.field(decision, :format) : invalid!
      asset_token = read_string(Types.field(decision, :asset_token)) || invalid!
      cs_declaration = read_string(Types.field(decision, :cs_declaration)) || invalid!
      constraints = Types.field(decision, :constraints)
      invalid! unless constraints.is_a?(Hash)

      Types::Decision.from_api(
        "slot_id" => slot_id, "status" => "ready", "fill" => true,
        "creative" => creative_for(format, decision),
        "asset_token" => asset_token, "constraints" => constraints, "cs_declaration" => cs_declaration,
        **revenue_estimate_field(decision), **metadata_field(decision)
      )
    end

    # @api private
    def creative_for(format, decision)
      delivery_url = read_string(Types.field(decision, :delivery_url))
      native_assets = native_assets_for(decision)
      invalid! if format == "native" ? native_assets.nil? : delivery_url.nil?

      width, height = creative_dimensions(decision)
      {
        "url" => format == "native" ? native_assets["image_url"] : delivery_url,
        "type" => format, "duration_ms" => creative_duration(decision), "width" => width, "height" => height,
        **optional_string_field(decision, :mime_type, "mime_type"),
        **optional_string_field(decision, :click_url, "click_through_url"),
        **optional_string_field(decision, :sponsor_name, "sponsor_name"),
        **(native_assets.nil? ? {} : { "native_assets" => native_assets })
      }
    end

    # Upstream requires +dimensions+ to be explicitly present: +null+ (use the
    # default box) or an object; an absent key is a contract violation.
    #
    # @api private
    def creative_dimensions(decision)
      invalid! unless decision.key?("dimensions") || decision.key?(:dimensions)
      dimensions = Types.field(decision, :dimensions)
      invalid! unless dimensions.nil? || dimensions.is_a?(Hash)

      [
        finite_number(dimensions && Types.field(dimensions, :width)) || DEFAULT_CREATIVE_WIDTH,
        finite_number(dimensions && Types.field(dimensions, :height)) || DEFAULT_CREATIVE_HEIGHT
      ]
    end

    # @api private
    def creative_duration(decision)
      finite_number(Types.field(decision, :duration_ms)) || DEFAULT_CREATIVE_DURATION_MS
    end

    # Port of upstream +readCanonicalNativeAssets+: title and image_url are
    # required, the remaining fields are kept only when non-blank.
    #
    # @api private
    def native_assets_for(decision)
      assets = Types.field(decision, :assets)
      return nil unless assets.is_a?(Hash)

      title = read_string(Types.field(assets, :title))
      image_url = read_string(Types.field(assets, :image_url))
      return nil if title.nil? || image_url.nil?

      { "title" => title, "image_url" => image_url,
        **optional_string_field(assets, :description, "description"),
        **optional_string_field(assets, :cta_text, "cta_text"),
        **optional_string_field(assets, :icon_url, "icon_url") }
    end

    # @api private
    def revenue_estimate_field(decision)
      revenue_estimate = Types.field(decision, :revenue_estimate)
      revenue_estimate.is_a?(Hash) ? { "revenue_estimate" => revenue_estimate } : {}
    end

    # @api private
    def metadata_field(hash)
      metadata = Types.field(hash, :metadata)
      metadata.is_a?(Hash) ? { "metadata" => metadata } : {}
    end

    # @api private
    def optional_string_field(hash, key, name)
      value = read_string(Types.field(hash, key))
      value.nil? ? {} : { name => value }
    end

    # Port of upstream +readString+: non-blank strings only, trimmed.
    #
    # @api private
    def read_string(value)
      value.is_a?(String) && !value.strip.empty? ? value.strip : nil
    end

    # @api private
    def finite_number(value)
      value.is_a?(Numeric) && value.to_f.finite? ? value : nil
    end

    # @api private
    def invalid!
      raise InvalidResponseError.new("Invalid decision response", code: "invalid_decision_response")
    end
  end
end
