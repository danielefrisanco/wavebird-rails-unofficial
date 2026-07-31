# frozen_string_literal: true

require_relative "../app/js_server"

Rails.application.routes.draw do
  mount Wavebird::Engine => "/wavebird"

  # ES modules straight from the gems that ship them (see JsServer).
  JsServer::ROOTS.each_key do |prefix|
    get "/#{prefix}/*path", to: JsServer, format: false
  end

  # The chat surface under test. Blocking is the default delivery mode; `async`
  # renders the same page with the Turbo Stream subscription (6b).
  get "chat", to: "chats#show"
  get "chat/async", to: "chats#show", defaults: { mode: "async" }, as: :async_chat

  root "chats#show"
end
