# frozen_string_literal: true

# A stand-in for a host app's AI chat surface. It renders a send button and a
# wavebird slot; the "AI turn" itself is a stub in the page's JavaScript, since
# what is under test is the wavebird glue around the turn, not the turn.
class ChatsController < ApplicationController
  include Wavebird::SessionId

  def show
    @async = params[:mode] == "async"
  end
end
