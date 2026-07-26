# frozen_string_literal: true

module Wavebird
  # Value objects mirroring the wavebird public contracts
  # (`public_contracts/wrapper.ts` + `common.ts` in the original TypeScript SDK,
  # and the canonical Server API response shapes — see docs/parity.md).
  #
  # Reading is tolerant by design: unknown response fields are preserved in
  # +raw+ (the API is documented to grow diagnostic fields), missing optional
  # fields resolve to +nil+, and keys may be strings or symbols. Field names
  # match the upstream contracts verbatim.
  #
  # +asset_token+ is sensitive proof material: it is redacted from +inspect+/
  # +to_s+ on every object that carries it, and +raw+ is never dumped.
  module Types
    # Placeholder shown instead of sensitive values in inspection output.
    REDACTED = "[REDACTED]"

    # Safe inspection for value objects: lists members except +raw+ (which may
    # contain sensitive fields) and masks sensitive members — +asset_token+
    # everywhere, plus anything the class adds via +.extra_sensitive_members+
    # (e.g. +frame_url+, whose path embeds the asset token).
    #
    # @api private
    module SafeInspect
      # Members masked in every value object's inspection output.
      DEFAULT_SENSITIVE_MEMBERS = [:asset_token].freeze

      # @return [String]
      def inspect
        "#<#{self.class.name} #{safe_fields.join(' ')}>"
      end

      # @return [String]
      def to_s
        inspect
      end

      private

      def sensitive_members
        extra = self.class.respond_to?(:extra_sensitive_members) ? self.class.extra_sensitive_members : []
        DEFAULT_SENSITIVE_MEMBERS + extra
      end

      def safe_fields
        self.class.members.filter_map do |member|
          next if member == :raw

          value = public_send(member)
          value = REDACTED if sensitive_members.include?(member) && !value.nil?
          "#{member}=#{value.inspect}"
        end
      end
    end

    # Fetches +key+ from a response hash, accepting string or symbol keys.
    #
    # @api private
    def self.field(hash, key)
      hash[key.to_s].nil? ? hash[key.to_sym] : hash[key.to_s]
    end

    # Builds keyword arguments for +members+ from a response hash.
    #
    # @api private
    def self.members_from(klass, hash)
      (klass.members - [:raw]).to_h { |member| [member, field(hash, member)] }
    end

    # Native creative assets (upstream +PublicNativeCreativeAssets+).
    NativeAssets = Data.define(:title, :image_url, :description, :cta_text, :icon_url, :raw) do
      include SafeInspect

      # @param hash [Hash, nil] response fragment
      # @return [NativeAssets, nil]
      def self.from_api(hash)
        return nil if hash.nil?

        new(**Types.members_from(self, hash), raw: hash)
      end
    end

    # Creative payload of a filled decision (upstream +CslWrapperDecisionFillV1["creative"]+).
    Creative = Data.define(:url, :type, :duration_ms, :width, :height, :mime_type, :click_through_url,
                           :vast_tracking, :sponsor_name, :native_assets, :raw) do
      include SafeInspect

      # @param hash [Hash, nil] response fragment
      # @return [Creative, nil]
      def self.from_api(hash)
        return nil if hash.nil?

        new(**Types.members_from(self, hash),
            native_assets: NativeAssets.from_api(Types.field(hash, :native_assets)),
            raw: hash)
      end
    end

    # Decision for a slot (upstream +CslWrapperDecisionResponseV1+ union:
    # pending / ready no-fill / ready fill).
    Decision = Data.define(:slot_id, :status, :fill, :reason, :no_fill_reason, :creative, :asset_token,
                           :constraints, :cs_declaration, :revenue_estimate, :metadata, :raw) do
      include SafeInspect

      # @param hash [Hash, nil] decision object from the API
      # @return [Decision, nil]
      def self.from_api(hash)
        return nil if hash.nil?

        new(**Types.members_from(self, hash),
            creative: Creative.from_api(Types.field(hash, :creative)),
            raw: hash)
      end

      # @return [Boolean] a creative was served (normal success case)
      def fill?
        fill == true
      end

      # @return [Boolean] the auction resolved with no creative — a normal,
      #   successful outcome; hide the slot and continue
      def no_fill?
        status == "ready" && fill != true
      end

      # @return [Boolean] no decision yet; poll again
      def pending?
        status == "pending"
      end

      # @return [Boolean] the decision is final (fill or no-fill)
      def ready?
        status == "ready"
      end
    end

    # Hosted-renderer instructions inside a placement (upstream
    # +WavebirdPlacement["render"]+, strategy +hosted_frame+).
    Render = Data.define(:strategy, :frame_url, :script_url, :media_type, :width, :height, :aspect_ratio,
                         :label_text, :sponsor_name, :click_url, :native_template_id, :raw) do
      include SafeInspect

      # +frame_url+ embeds the asset token (+/v1/render/{asset_token}+), so it
      # is masked in inspection output alongside +asset_token+.
      #
      # @return [Array<Symbol>]
      def self.extra_sensitive_members
        [:frame_url]
      end

      # @param hash [Hash, nil] response fragment
      # @return [Render, nil]
      def self.from_api(hash)
        return nil if hash.nil?

        new(**Types.members_from(self, hash), raw: hash)
      end
    end

    # Renderable placement (upstream +WavebirdPlacement+ / Server API
    # +placement+ object).
    Placement = Data.define(:image_url, :video_url, :click_url, :sponsor_name, :width, :height, :format,
                            :asset_token, :ad_label_text, :render, :raw) do
      include SafeInspect

      # @param hash [Hash, nil] placement object from the API (null on no-fill)
      # @return [Placement, nil]
      def self.from_api(hash)
        return nil if hash.nil?

        new(**Types.members_from(self, hash),
            render: Render.from_api(Types.field(hash, :render)),
            raw: hash)
      end
    end

    # Response of +POST /v1/placements+ (job + first decision in one call).
    #
    # +placement+ is +nil+ on no-fill — a first-class, successful case: hide
    # the ad slot and continue normally.
    PlacementResponse = Data.define(:slot_id, :status, :placement, :decision, :raw) do
      include SafeInspect

      # @param hash [Hash] response body
      # @return [PlacementResponse]
      def self.from_api(hash)
        new(**Types.members_from(self, hash),
            placement: Placement.from_api(Types.field(hash, :placement)),
            decision: Decision.from_api(Types.field(hash, :decision)),
            raw: hash)
      end

      # @return [Boolean] a placement is present and the decision filled
      def fill?
        !placement.nil? && !decision.nil? && decision.fill?
      end

      # @return [Boolean] hide the slot and continue (normal outcome)
      def no_fill?
        !fill?
      end
    end

    # Accepted job metadata from +POST /v1/jobs+ (upstream +AcceptedJobResponse+).
    AcceptedJob = Data.define(:job_id, :slot_ids, :status, :raw) do
      include SafeInspect

      # @param hash [Hash] response body
      # @return [AcceptedJob]
      def self.from_api(hash)
        new(**Types.members_from(self, hash), raw: hash)
      end
    end

    # Acknowledgement from +POST /v1/beacons+. Members cover the documented
    # fields; this endpoint is diagnostics-heavy and may grow fields — extras
    # stay available via +raw+.
    BeaconResult = Data.define(:ok, :accepted, :duplicate, :reason_code, :raw) do
      include SafeInspect

      # @param hash [Hash] response body
      # @return [BeaconResult]
      def self.from_api(hash)
        new(**Types.members_from(self, hash), raw: hash)
      end

      # @return [Boolean] the beacon was accepted (idempotent duplicates are
      #   also a success, flagged via +duplicate+)
      def accepted?
        accepted == true
      end

      # @return [Boolean] this beacon_id was already recorded
      def duplicate?
        duplicate == true
      end
    end

    # Acknowledged consent state from +POST /v1/consent+ (docs §"Consent in
    # GenAI apps"). Tolerant: exact response shape is server-owned.
    ConsentState = Data.define(:decision, :source, :purposes, :raw) do
      include SafeInspect

      # @param hash [Hash] response body
      # @return [ConsentState]
      def self.from_api(hash)
        new(**Types.members_from(self, hash), raw: hash)
      end
    end

    # Short-lived browser activation grant from +POST /v1/browser/activate+
    # (upstream +BrowserActivationResponse+). Secondary path — only needed for
    # Script Tag / pure-browser integrations.
    BrowserActivation = Data.define(:activation_token, :expires_at_ms, :raw) do
      include SafeInspect

      # +activation_token+ is a short-lived Bearer credential, masked like the
      # other proof material.
      #
      # @return [Array<Symbol>]
      def self.extra_sensitive_members
        [:activation_token]
      end

      # @param hash [Hash] response body
      # @return [BrowserActivation]
      def self.from_api(hash)
        new(**Types.members_from(self, hash), raw: hash)
      end
    end

    # Non-secret runtime project configuration from
    # +GET /v1/projects/{client_id}/config+. Shape is server-owned; access
    # fields via {#[]}.
    ProjectConfig = Data.define(:raw) do
      include SafeInspect

      # @param hash [Hash] response body
      # @return [ProjectConfig]
      def self.from_api(hash)
        new(raw: hash)
      end

      # @param key [String, Symbol]
      # @return [Object, nil]
      def [](key)
        Types.field(raw, key)
      end
    end
  end
end
