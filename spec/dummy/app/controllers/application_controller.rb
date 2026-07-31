# frozen_string_literal: true

class ApplicationController < ActionController::Base
  # The engine isolates its namespace, so a host opts its views into the slot
  # helpers explicitly. This mirrors what a real host app does — and what
  # INSTALL.md documents.
  helper Wavebird::SlotHelper
end
