# frozen_string_literal: true

# Being one file is the point of this example, so the usual one-class-per-file
# rule does not apply to it.
# rubocop:disable Style/OneClassPerFile

# A complete wavebird-rails integration in one runnable file.
#
# From a clone of this repo:
#
#   bundle exec ruby examples/single_file_chat.rb
#
# Or from any app that already has the gem and puma installed:
#
#   ruby examples/single_file_chat.rb
#
# Then open http://localhost:3000.
#
# No `rails new`, no database, no build step, no importmap. Everything a host app
# needs is here: the engine mounted, the initializer, the helper opt-in, the slot,
# and the turn wiring. Read it top to bottom and you have seen the integration.
#
# It runs **without a wavebird key**. The client is fail-silent by design, so an
# unconfigured key produces a no-fill: the slot stays hidden and the chat still
# works. That is the intended failure mode, so running it unconfigured is the
# quickest way to confirm the ad path cannot break your app. Export a sandbox key
# to see real placements:
#
#   WAVEBIRD_SECRET_KEY=sk_test_... WAVEBIRD_CLIENT_ID=wbproj_... \
#     bundle exec ruby examples/single_file_chat.rb

require "action_controller/railtie"
require "puma"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
# The gem-named entry point: it pulls in the engine (and its routes, helpers and
# controller) once Rails is loaded. Requiring "wavebird" alone gives you the
# client without any of the Rails glue.
require "wavebird-rails"

# --------------------------------------------------------------------------
# 1. Configuration — the initializer a host app puts in config/initializers/.
# --------------------------------------------------------------------------
#
# This must never live under app/assets or app/javascript: the secret key would
# become reachable from the browser. The gem's Railtie raises at boot if it does.
Wavebird.configure do |config|
  # sk_test_... (sandbox), sk_dry_... (production dry run) or sk_live_...
  # A callable is accepted too, resolved immediately before each request, which
  # is what you want when a secrets manager rotates keys.
  config.secret_key = ENV.fetch("WAVEBIRD_SECRET_KEY", "")
  config.client_id  = ENV.fetch("WAVEBIRD_CLIENT_ID", "")
  config.logger     = Logger.new($stdout)

  # The shape you want the slot auctioned for, sent with every placement.
  config.default_slot_hint = { position: "below", max_width: 728, max_height: 90 }

  # The gem swallows failures by design, so this is how you learn wavebird was
  # unreachable. In a real app: Rails.error.report(error, handled: true)
  config.on_error = ->(error) { warn("[wavebird] swallowed: #{error.class}: #{error.message}") }
end

# The whole Rails app. A real host app has this in config/application.rb and does
# not need most of it — the settings here exist only to run without a generated
# app skeleton on disk.
class ChatDemo < Rails::Application
  config.root = __dir__
  config.eager_load = false
  config.consider_all_requests_local = true
  config.secret_key_base = "single_file_example_not_a_real_secret"
  config.hosts.clear
  config.logger = Logger.new($stdout)
  config.log_level = :warn
end

Rails.application.initialize!

# --------------------------------------------------------------------------
# 2. Routes — mount the engine, which provides POST /wavebird/sponsor_slot.
# --------------------------------------------------------------------------
Rails.application.routes.draw do
  mount Wavebird::Engine => "/wavebird"
  root "chats#show"
  post "/messages", to: "chats#reply"
end

# --------------------------------------------------------------------------
# 3. The host controller — the two lines that opt into wavebird.
# --------------------------------------------------------------------------
class ChatsController < ActionController::Base
  # The engine isolates its namespace, so wavebird_slot and
  # wavebird_render_script_tag are not mixed into host views automatically.
  helper Wavebird::SlotHelper

  # Gives us wavebird_session_id: a stable, anonymous "sess_" + UUID per browser.
  # Never a user id — wavebird receives nothing that identifies your users. If you
  # substitute your own id it must be unguessable and per-browser, because async
  # delivery scopes its Turbo Stream to it.
  include Wavebird::SessionId

  def show
    render inline: TEMPLATE, layout: false
  end

  # Stands in for your real AI endpoint. Sleeps so the sponsored slot is visible
  # for the length of a turn, which is the whole point of the integration.
  def reply
    sleep 3
    render json: { reply: "You said: #{params[:message]}" }
  end
end

# --------------------------------------------------------------------------
# 4. The page — the slot, and handing your turn to wavebird.
# --------------------------------------------------------------------------
# The quotes on the heredoc delimiter are load-bearing, not decoration: the
# template is full of `<%# … %>` ERB comments, and in an interpolating heredoc
# `<%#{...}` is read as Ruby interpolation, silently turning a comment into an
# open `<% %>` tag around prose. That exact bug cost a debugging round while
# writing this file. RuboCop sees no `#{` today and calls the quotes redundant;
# they are what stops the next edit from reintroducing it.
# rubocop:disable Style/RedundantHeredocDelimiterQuotes
TEMPLATE = <<~'ERB'
  <!doctype html>
  <html>
    <head><title>wavebird-rails single-file example</title></head>
    <body style="font-family: system-ui; max-width: 40rem; margin: 3rem auto;">
      <h1>Chat</h1>
      <div id="messages"></div>

      <form id="composer">
        <input type="text" name="message" placeholder="Ask something…" style="width: 20rem;">
        <button type="submit">Send</button>
      </form>

      <%#
        Loads wavebird's hosted renderer once per page. Optional — the gem can load
        it lazily — but emitting it here lets the browser start fetching earlier.
      %>
      <%= wavebird_render_script_tag %>

      <%#
        The slot: a plain <section>, rendered hidden. wavebird's renderer owns it
        from here, revealing it and mounting a frame on a fill, leaving it hidden
        on a no-fill.
      %>
      <%= wavebird_slot endpoint: wavebird.sponsor_slot_path,
                        session_id: wavebird_session_id,
                        position: "below" %>

      <script type="module">
        // Your real AI call. Anything returning a promise works.
        async function sendChatMessage(message) {
          const response = await fetch("/messages", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ message }),
          });
          const data = await response.json();
          document.querySelector("#messages").insertAdjacentHTML(
            "beforeend", `<p>${data.reply}</p>`
          );
        }

        const composer = document.querySelector("#composer");
        const slot = document.querySelector("#wavebird-slot-below");

        composer.addEventListener("submit", (event) => {
          event.preventDefault();
          const message = new FormData(composer).get("message");
          const send = () => sendChatMessage(message);

          // Hand the turn to wavebird: it auctions a placement while your answer
          // generates. Passing `body` explicitly is what sends the app's *stable*
          // session id — render.js's own default body is a fresh random one per
          // turn. The slot carries both values as data attributes for this.
          //
          // The guard matters: if render.js was blocked or never loaded, the turn
          // still runs. The ad path must never be able to break the chat.
          if (window.wavebird?.withTurn) {
            window.wavebird.withTurn(
              {
                target: slot,
                body: {
                  session_id: slot.dataset.wavebirdSessionIdValue,
                  position: slot.dataset.wavebirdPositionValue,
                },
              },
              send,
            );
          } else {
            send();
          }
        });
      </script>
    </body>
  </html>
ERB
# rubocop:enable Style/RedundantHeredocDelimiterQuotes

port = ENV.fetch("PORT", 3000).to_i
puts "\n  wavebird-rails single-file example -> http://localhost:#{port}"
puts "  secret key: #{Wavebird.configuration.secret_key.to_s.empty? ? 'not set (expect no-fill)' : 'set'}\n\n"

# Puma's server API directly, rather than a Rack handler: the handler namespace
# moved between rack 2, rack 3 and the extracted rackup gem, and this works
# across all of them.
server = Puma::Server.new(Rails.application)
server.add_tcp_listener("127.0.0.1", port)
server.run
sleep
# rubocop:enable Style/OneClassPerFile
