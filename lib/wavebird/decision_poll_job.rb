# frozen_string_literal: true

# Background poller for async delivery mode (decision #001).
#
# ActiveJob is an *optional* runtime dependency: the gem's blocking default needs
# only faraday + railties, so this file lives under +lib/+ (off the engine's
# Zeitwerk autoload path) and is +require+d lazily by {Wavebird::SponsorSlotsController}
# only on the async path — which is reached only when Turbo/ActiveJob is also
# present. The early return still guards the definition so requiring this file in
# an app without ActiveJob is a no-op rather than a NameError.
#
# :nocov: — load-time environment guard; a single test process either has
# ActiveJob or it does not, so only one side of this early return is ever taken.
return unless defined?(ActiveJob::Base)
# :nocov:

module Wavebird
  # Enqueued after a non-blocking +create_job+; holds the decision long-poll open
  # server-side (zero added chat latency for the host) and, once a decision is
  # ready, broadcasts a Turbo Stream that reveals or hides the slot.
  #
  # Fail-silent by contract (decision #003): it polls through {Wavebird.client}
  # (the facade), which turns any error — including a polling-budget timeout —
  # into a synthetic no-fill, so the broadcast simply hides the slot and the
  # host's chat flow is never disrupted.
  class DecisionPollJob < ActiveJob::Base
    queue_as { Wavebird.configuration.async_queue_name }

    # @param slot_id [String] the slot to poll (from the accepted job)
    # @param stream_name [String] the session-scoped Turbo Stream the browser
    #   subscribed to (see {SlotPayload.stream_name})
    # @param position [String] slot position, which the broadcast target's DOM id
    #   is built from
    def perform(slot_id, stream_name, position)
      decision = Wavebird.client.await_decision(slot_id)
      broadcast(stream_name, position, decision)
    end

    private

    # Broadcasts the reveal/hide instruction to the slot's stream. It carries only
    # the browser-safe payload ({SlotPayload}) — never the secret key, and never
    # the bare +asset_token+ (the server folds it into +frame_url+). The broadcast
    # is guarded so a queue that runs without Turbo loaded degrades to a no-op
    # rather than raising into the host's job backend.
    def broadcast(stream_name, position, decision)
      return unless defined?(Turbo::StreamsChannel)

      # Appended *into* the slot <section>, not replacing an element of its own:
      # the signal has to land inside the controller's element for Stimulus to
      # see it as a target, and `append` works whether or not an earlier signal
      # is present (a `replace` against a missing target is a silent no-op).
      Turbo::StreamsChannel.broadcast_append_to(
        stream_name,
        target: SlotPayload.slot_dom_id(position),
        partial: "wavebird/slot_broadcast",
        locals: { payload: SlotPayload.call(decision) }
      )
    end
  end
end
