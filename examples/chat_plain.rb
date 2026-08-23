# frozen_string_literal: true

# Being one file is the point of this example, so the usual one-class-per-file
# rule does not apply to it.
# rubocop:disable Style/OneClassPerFile

# wavebird-rails **without Hotwire** — the whole integration in one runnable file.
#
#   bundle exec ruby examples/chat_plain.rb        # from a clone of this repo
#   open http://localhost:3000
#
# No `rails new`, no database, no build step, no importmap, no Stimulus. The
# counterpart with Hotwire is examples/chat_hotwire.rb.
#
# It runs **without a wavebird key**: the client is fail-silent, so an
# unconfigured key produces a no-fill — the slot stays hidden and the chat still
# works. The status panel on the page says which of those happened, so an empty
# slot is never ambiguous. For real sandbox placements:
#
#   WAVEBIRD_SECRET_KEY=sk_test_... WAVEBIRD_CLIENT_ID=wbproj_... \
#     bundle exec ruby examples/chat_plain.rb

require "action_controller/railtie"
require "puma"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
# The gem-named entry point: it pulls in the engine (routes, helpers, controller)
# once Rails is loaded. Requiring "wavebird" alone gives the client with no glue.
require "wavebird-rails"

# Read the gitignored .env.test if it is there — the same file the test suite
# uses for sandbox credentials, so a key you already configured for `rake` works
# here without being repeated on the command line. Entirely optional: dotenv is a
# development dependency, and without it the example still runs fail-silent.
begin
  require "dotenv"
  Dotenv.load(File.expand_path("../.env.test", __dir__))
rescue LoadError
  nil
end

# Records the last swallowed failure so the page can say *why* a slot is empty.
#
# The gem is fail-silent by design: a wavebird outage, a rejected request and an
# honest empty auction all reach the browser as the same `{"fill": false}`, so
# the ad path can never break a chat turn. That is right for production and
# actively unhelpful in a demo -- it is what made "Consent is not current" look
# like "no eligible campaign" until someone read the server log.
#
# This is **example-only scaffolding, not something the gem ships**: it hands the
# browser an internal error string, which a real app should not do. `on_error` is
# the supported seam; in production it goes to your error tracker, not to a page.
module Wavebird
  # Last-swallowed-error holder for the examples' status panel.
  module ExampleDiagnostics
    module_function

    def record(error)
      @mutex ||= Mutex.new
      @mutex.synchronize { @last = "#{error.class.name.split('::').last}: #{error.message}" }
    end

    # Read-and-clear: each turn reports its own failure, never a stale one.
    def take
      @mutex ||= Mutex.new
      @mutex.synchronize { @last.tap { @last = nil } }
    end
  end
end

# --------------------------------------------------------------------------
# 1. Configuration — the initializer a host app puts in config/initializers/.
# --------------------------------------------------------------------------
Wavebird.configure do |config|
  # sk_test_ (sandbox), sk_dry_ (production dry run) or sk_live_. A callable is
  # accepted too, resolved immediately before each request, which is what you
  # want when a secrets manager rotates keys.
  config.secret_key = ENV.fetch("WAVEBIRD_SECRET_KEY", "")
  config.client_id  = ENV.fetch("WAVEBIRD_CLIENT_ID", "")
  config.logger     = Logger.new($stdout)
  config.default_slot_hint = { position: "below", max_width: 728, max_height: 90 }

  # **Required, or no ad is ever requested.** wavebird's hosted renderer gates
  # every turn on this object and refuses silently without it -- no request, no
  # error, nothing in the console. It is your consent management system's answer
  # about this visitor, which is why only you can supply it; the gem never
  # invents one. Resolved fresh on each slot render, so a withdrawal takes
  # effect on the next turn.
  #
  # Hard-coded here because an example has no CMP. A real app reads its own
  # consent record: `MyConsentStore.for(Current.session)`.
  config.authoritative_consent = lambda do
    { lifecycle_state: "granted", expires_at_ms: (Time.now.to_i + 3600) * 1000 }
  end

  # The gem swallows failures by design, so this is how you learn wavebird was
  # unreachable. In a real app: Rails.error.report(error, handled: true)
  config.on_error = lambda { |error|
    warn("[wavebird] swallowed: #{error.class}: #{error.message}")
    Wavebird::ExampleDiagnostics.record(error)
  }
end

# Reports which credentials are present without ever printing their values —
# "not configured" mid-turn is a confusing way to learn a key was missing.
module Wavebird
  # Startup credential check for the examples.
  module ExampleCredentials
    module_function

    def summary
      parts = [describe("WAVEBIRD_SECRET_KEY", "sk_", Wavebird.configuration.secret_key),
               describe("WAVEBIRD_CLIENT_ID", "wbproj_", Wavebird.configuration.client_id)]
      return "credentials: #{parts.join(', ')} — expect real placements" if parts.all? { |p| p.end_with?("ok") }

      "credentials: #{parts.join(', ')}\n  " \
        "without both, every turn is a no-fill (slot hidden, chat still works)"
    end

    # Checks the prefix too: putting a secret key in CLIENT_ID is an easy slip,
    # and it fails as a rejected placement rather than as a missing credential.
    def describe(name, prefix, value)
      value = value.to_s
      return "#{name} missing" if value.empty?
      return "#{name} set but does not start with #{prefix}" unless value.start_with?(prefix)

      "#{name} ok"
    end
  end
end

# The whole Rails app. A real host has this in config/application.rb and needs
# almost none of it — these settings only exist to run without an app skeleton.
class ChatPlainDemo < Rails::Application
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
  # Example-only: lets the status panel report why a slot is empty. Not part of
  # the gem, and not something to copy into a real app.
  get "/demo/diagnostics", to: "chats#diagnostics"
end

# --------------------------------------------------------------------------
# 3. The host controller — the two lines that opt into wavebird.
# --------------------------------------------------------------------------
class ChatsController < ActionController::Base
  # The engine isolates its namespace, so wavebird_slot and
  # wavebird_render_script_tag are not mixed into host views automatically.
  helper Wavebird::SlotHelper

  # Gives us wavebird_session_id: a stable, anonymous "sess_" + UUID per browser.
  # Never a user id. A substitute must be unguessable and per-browser.
  include Wavebird::SessionId

  def show
    render inline: TEMPLATE, layout: false
  end

  # Stands in for your real AI endpoint. The delay is deliberate: it is the
  # window wavebird auctions a placement in, so you can watch both happen.
  def reply
    sleep 2
    render json: { reply: "You said: #{params[:message]}" }
  end

  # Example-only. See Wavebird::ExampleDiagnostics.
  def diagnostics
    render json: { last_error: Wavebird::ExampleDiagnostics.take }
  end
end

# --------------------------------------------------------------------------
# 4. The page — the slot, and handing your turn to wavebird.
# --------------------------------------------------------------------------
# The heredoc delimiter quotes are load-bearing: the template contains `<%# … %>`
# ERB comments, and in an interpolating heredoc `<%#{...}` parses as Ruby
# interpolation, silently turning a comment into an open `<% %>` tag.
# rubocop:disable Style/RedundantHeredocDelimiterQuotes
TEMPLATE = <<~'ERB'
  <!doctype html>
  <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>wavebird-rails — chat without Hotwire</title>
      <style>
        :root {
          color-scheme: light;
          --bg: #f6f1e7; --panel: #fffaf2; --border: #d7cbb5;
          --accent: #8f4b24; --accent-strong: #5d2f12;
          --text: #21170f; --muted: #6d5849;
        }
        * { box-sizing: border-box; }
        body {
          margin: 0; color: var(--text);
          font-family: "IBM Plex Sans", "Segoe UI", system-ui, sans-serif;
          background:
            radial-gradient(circle at top, rgba(217, 162, 98, .28), transparent 30%),
            linear-gradient(180deg, #f9f4ea 0%, var(--bg) 100%);
        }
        main { max-width: 780px; margin: 0 auto; padding: 32px 20px 56px; }
        h1 {
          margin: 0 0 6px; font-size: clamp(1.6rem, 3vw, 2.4rem);
          font-family: "IBM Plex Serif", Georgia, serif;
        }
        .lede { color: var(--muted); margin: 0 0 24px; }
        .panel {
          background: var(--panel); border: 1px solid var(--border);
          border-radius: 12px; padding: 18px; margin-bottom: 18px;
        }
        .panel h2 {
          margin: 0 0 12px; font-size: .75rem; letter-spacing: .08em;
          text-transform: uppercase; color: var(--muted);
        }
        #messages p {
          margin: 0 0 10px; padding: 10px 14px; border-radius: 10px;
          background: rgba(143, 75, 36, .07);
        }
        #messages:empty::after { content: "No messages yet."; color: var(--muted); }
        form { display: flex; gap: 10px; }
        input[type=text] {
          flex: 1; padding: 11px 14px; font: inherit;
          border: 1px solid var(--border); border-radius: 9px; background: #fff;
        }
        button {
          padding: 11px 20px; font: inherit; font-weight: 600; cursor: pointer;
          color: #fff; background: var(--accent); border: 0; border-radius: 9px;
        }
        button:hover { background: var(--accent-strong); }
        button[disabled] { opacity: .55; cursor: default; }
        #status { margin: 0; font-size: .85rem; color: var(--muted); line-height: 1.7; }
        #status b { color: var(--text); font-weight: 600; }
        code { font-family: "IBM Plex Mono", ui-monospace, monospace; font-size: .85em; }
      </style>
    </head>
    <body>
      <main>
        <h1>Chat, without Hotwire</h1>
        <p class="lede">
          A sponsored slot auctioned while the answer generates. No importmap, no
          Stimulus — just <code>window.wavebird.withTurn(...)</code>.
        </p>

        <div class="panel">
          <h2>Conversation</h2>
          <div id="messages"></div>
          <form id="composer">
            <input type="text" name="message" placeholder="Ask something…" autocomplete="off">
            <button type="submit">Send</button>
          </form>
        </div>

        <%#
          Loads wavebird's hosted renderer once per page. Optional — the gem can
          load it lazily — but emitting it here starts the fetch earlier.
        %>
        <%= wavebird_render_script_tag %>

        <%#
          The slot: a plain <section>, rendered hidden. wavebird's renderer owns
          it from here, revealing it and mounting a frame on a fill.
        %>
        <%= wavebird_slot endpoint: wavebird.sponsor_slot_path,
                          session_id: wavebird_session_id,
                          position: "below" %>

        <div class="panel">
          <h2>What just happened</h2>
          <p id="status">Send a message to start a turn.</p>
        </div>
      </main>

      <script type="module">
        const composer = document.querySelector("#composer");
        const button   = composer.querySelector("button");
        const input    = composer.querySelector("input");
        const messages = document.querySelector("#messages");
        const status   = document.querySelector("#status");
        const slot     = document.querySelector("#wavebird-slot-below");

        // Without this panel an empty slot is ambiguous: a no-fill and a broken
        // integration look identical, which is exactly the trap that hid #017.
        function report(lines) { status.innerHTML = lines.join("<br>"); }

        // Example-only endpoint; see Wavebird::ExampleDiagnostics. A real app
        // sends on_error to its error tracker, never to the browser.
        async function slotReason() {
          try {
            const response = await fetch("/demo/diagnostics");
            const { last_error: lastError } = await response.json();
            if (lastError) {
              const escaped = new Option(lastError).innerHTML;
              return `<b>slot</b> hidden — wavebird <b>rejected the request</b>: ${escaped}<br>` +
                     "This is a real failure, not an empty auction. The chat was unaffected.";
            }
          } catch {
            // Diagnostics are a convenience; never let them break the panel.
          }
          return "<b>slot</b> hidden — no-fill: no key configured, or no eligible campaign. " +
                 "wavebird answered normally and had nothing to show. This is a success, not an error.";
        }

        async function sendChatMessage(message) {
          const response = await fetch("/messages", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ message }),
          });
          const data = await response.json();
          // textContent, not innerHTML: a reply is untrusted content. Here it is
          // your own echo, but the moment this is a real model call it becomes
          // attacker-influenceable through prompt injection.
          const line = document.createElement("p");
          line.textContent = data.reply;
          messages.appendChild(line);
        }

        composer.addEventListener("submit", async (event) => {
          event.preventDefault();
          const message = input.value.trim();
          if (!message) return;
          input.value = "";
          button.disabled = true;

          const body = {
            session_id: slot.dataset.wavebirdSessionIdValue,
            position: slot.dataset.wavebirdPositionValue,
          };
          // Present only when the slot was rendered async: true. The endpoint
          // reads the delivery mode from the body, so omitting it quietly
          // serves the blocking path.
          if (slot.dataset.wavebirdModeValue) body.mode = slot.dataset.wavebirdModeValue;

          // The hosted renderer refuses the turn without this: startTurn checks
          // authoritative_consent before it fetches anything and returns a null
          // decision, so the endpoint is never called and nothing is logged.
          // The view helper serialises it onto the slot; read it back here.
          let consent = null;
          try {
            const raw = slot.dataset.wavebirdConsentValue;
            if (raw) consent = JSON.parse(raw);
          } catch { /* a broken consent config costs the ad, never the chat turn */ }

          const send = () => sendChatMessage(message);
          const loaded = Boolean(window.wavebird?.withTurn);

          report([
            `<b>render.js</b> ${loaded ? "loaded" : "not loaded — running the turn unwrapped"}`,
            "<b>turn</b> started, placement requested…",
          ]);

          // The guard matters: if render.js was blocked or never loaded, the
          // turn still runs. The ad path must never break the chat.
          if (loaded) {
            const input = { target: slot, body };
            if (consent) input.authoritative_consent = consent;
            await window.wavebird.withTurn(input, send);
          } else {
            await send();
          }

          const filled = slot.hidden === false;
          // An empty slot has three causes that look identical from here: an
          // honest no-fill, a missing key, and a request wavebird rejected. The
          // gem swallows the third by design, so ask the server which it was
          // rather than guessing in the copy -- guessing is what made a real
          // "Consent is not current" read as "no eligible campaign".
          const why = filled ? null : await slotReason();
          report([
            `<b>render.js</b> ${loaded ? "loaded" : "not loaded"}`,
            "<b>turn</b> finished, answer delivered",
            filled ? "<b>slot</b> filled — wavebird returned a placement" : why,
          ]);
          button.disabled = false;
          input.focus();
        });
      </script>
    </body>
  </html>
ERB
# rubocop:enable Style/RedundantHeredocDelimiterQuotes

port = ENV.fetch("PORT", 3000).to_i
puts "\n  wavebird-rails — chat WITHOUT Hotwire -> http://localhost:#{port}"
puts "  #{Wavebird::ExampleCredentials.summary}\n\n"

# Puma's server API directly rather than a Rack handler: the handler namespace
# moved between rack 2, rack 3 and the extracted rackup gem.
server = Puma::Server.new(Rails.application)
server.add_tcp_listener("127.0.0.1", port)
server.run
sleep
# rubocop:enable Style/OneClassPerFile
