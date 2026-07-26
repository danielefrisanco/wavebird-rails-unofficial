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
  # Apps that already have their own anonymous session id can skip the concern
  # and pass that value instead.
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
