# frozen_string_literal: true

# Your chat surface. Note what is *not* here: no wavebird call, no key handling,
# no ad logic. The slot requests itself from the browser through the mounted
# engine, so the sponsored placement is additive to your app rather than
# entangled with it — if you delete the wavebird lines from the view, this
# controller keeps working unchanged.
class ChatsController < ApplicationController
  def show
    @messages = current_conversation_messages
  end

  private

  def current_conversation_messages
    session[:messages] ||= []
  end
end
