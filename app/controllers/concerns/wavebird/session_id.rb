# frozen_string_literal: true

require "securerandom"

module Wavebird
  # Controller concern that lazily assigns a stable, anonymous per-browser
  # session id for wavebird slot requests and stores it in the Rails session.
  #
  # The id is deliberately anonymous — a random +sess_+ token, never a user id or
  # anything PII (privacy §4). Include it in a host controller (or
  # +ApplicationController+) and pass {#wavebird_session_id} to {SlotHelper#wavebird_slot}:
  #
  #   class ApplicationController < ActionController::Base
  #     include Wavebird::SessionId
  #   end
  #
  #   <%= wavebird_slot(session_id: wavebird_session_id, endpoint: wavebird.sponsor_slot_path) %>
  #
  # Apps that already have their own anonymous session id can skip the concern and
  # pass that value instead, provided it is **unguessable and per-browser** — a
  # random token, not a user id, email hash, or anything sequential.
  #
  # That is a security requirement, not a style preference. In async delivery the
  # Turbo Stream carrying a decision is named from the position *and* this id
  # ({SlotPayload.stream_name}), and the endpoint derives the broadcast target
  # from the id the request supplies. A guessable id lets one visitor address
  # another visitor's stream — pushing a placement into their page and firing
  # their beacons from an unrelated browser, which is exactly the cross-session
  # leak decision #015 closed. The scoping holds because {#wavebird_session_id} is
  # a +SecureRandom.uuid+; a substitute inherits that duty.
  #
  # Blocking delivery has no stream at all, so nothing is shared there either way.
  module SessionId
    extend ActiveSupport::Concern

    included do
      helper_method :wavebird_session_id if respond_to?(:helper_method)
    end

    # The current anonymous wavebird session id, generating and persisting one on
    # first use.
    #
    # @return [String]
    def wavebird_session_id
      session[:wavebird_session_id] ||= "sess_#{SecureRandom.uuid}"
    end
  end
end
