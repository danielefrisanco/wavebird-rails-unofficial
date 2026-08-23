# frozen_string_literal: true

# Being one file is the point of this example, so the usual one-class-per-file
# rule does not apply to it.
# rubocop:disable Style/OneClassPerFile

# wavebird-rails **with React** — the whole integration in one runnable file.
#
#   bundle exec ruby examples/chat_react.rb          # from a clone of this repo
#   open http://localhost:3000
#
# No `rails new`, no database, **no build step and no bundler**: React, ReactDOM
# and htm are loaded as ES modules from a CDN, the same trick chat_hotwire.rb
# uses for Stimulus. htm gives JSX-like markup in a tagged template literal, so
# there is no transpiler in the loop.
#
# **The gem ships no React code, and that is the point.** The seam a React app
# needs already exists and is framework-agnostic:
#
#   window.wavebird.withTurn({ target, body }, work)
#
# So this example is not a port of upstream's React bindings — those sit beside
# `mount` DOM builders that upstream itself deprecated. It is a ~20 line
# `useWavebirdTurn` hook you copy into your own app. The same hook is written out
# in INSTALL.md; this file is the proof it runs.
#
# It runs **without a wavebird key**: the client is fail-silent, so an
# unconfigured key produces a no-fill — the slot stays hidden and the chat still
# works. The status panel on the page says which of those happened, so an empty
# slot is never ambiguous. For real sandbox placements:
#
#   WAVEBIRD_SECRET_KEY=sk_test_... WAVEBIRD_CLIENT_ID=wbproj_... \
#     bundle exec ruby examples/chat_react.rb

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
      # diagnostic_message, not message: wavebird's `message` is often generic
      # ("check the request body schema") while reason_code names the actual
      # cause. The panel exists to end guessing, so it shows everything sent.
      described = error.respond_to?(:diagnostic_message) ? error.diagnostic_message : error.message
      @mutex.synchronize { @last = "#{error.class.name.split('::').last}: #{described}" }
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
    warn("[wavebird] swallowed: #{error.class}: " \
         "#{error.respond_to?(:diagnostic_message) ? error.diagnostic_message : error.message}")
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
class ChatReactDemo < Rails::Application
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
    ensure_consent_recorded
    render inline: TEMPLATE, layout: false
  end

  # Stands in for your real AI endpoint. The delay is deliberate: it is the
  # window wavebird auctions a placement in, so you can watch both happen.
  def reply
    sleep 2
    render json: { reply: "You said: #{params[:message]}" }
  end

  # wavebird's API tracks consent **per session**, separately from the
  # browser-side gate in config.authoritative_consent. A project whose
  # consent_mode requires it answers every placement with "Consent is not
  # current" until a consent record exists for that session id.
  #
  # Recorded once per browser session here. A real app records it when the
  # visitor actually answers your consent dialog, not on page load -- doing it
  # unconditionally, as this example does, asserts a consent nobody gave and is
  # only acceptable because there is no real visitor.
  def ensure_consent_recorded
    return if session[:wavebird_consent_recorded]

    Wavebird.client.record_consent(decision: "personalized", source: "wavebird_dialog",
                                   session_id: wavebird_session_id,
                                   purposes: { semantic_targeting: true, prompt_shared: true })
    session[:wavebird_consent_recorded] = true
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
      <title>wavebird-rails — chat with React</title>
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
        <h1>Chat, with React</h1>
        <p class="lede">
          A sponsored slot auctioned while the answer generates, driven from a
          React component through a <code>useWavebirdTurn</code> hook. No build
          step: React and htm load as ES modules from a CDN.
        </p>

        <%# React mounts the chat here. The slot below is deliberately
            outside this root — see the comment by createRoot. %>
        <div id="chat-root"></div>

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

        <%# The second React root. The slot sits between the two and belongs
            to neither — see the comment by createRoot. %>
        <div class="panel">
          <h2>What just happened</h2>
          <div id="status-root"></div>
        </div>
      </main>

      <script type="module">
        // React with no build step: htm turns a tagged template literal into
        // React.createElement calls, so there is no JSX to transpile. A real app
        // would use its own bundler; nothing here depends on this trick.
        import React, { useState, useCallback, useRef } from "https://esm.sh/react@18.3.1";
        import { createRoot } from "https://esm.sh/react-dom@18.3.1/client";
        import { createPortal } from "https://esm.sh/react-dom@18.3.1";
        import htm from "https://esm.sh/htm@3.1.1";

        const html = htm.bind(React.createElement);

        // ------------------------------------------------------------------
        // useWavebirdTurn — the whole React integration. Copy this into your app.
        // ------------------------------------------------------------------
        //
        // It does not touch React state, render anything, or own the slot: the
        // hosted renderer owns that <section>, and React must not fight it over
        // the same DOM. The hook's only job is to wrap the work of one chat turn
        // so wavebird can auction a placement while the answer generates.
        function useWavebirdTurn(slotId) {
          // A ref, not state: reading the slot must never trigger a re-render,
          // and the element is owned by the renderer rather than by React.
          const slotRef = useRef(null);

          return useCallback(async (work) => {
            const slot = slotRef.current ?? (slotRef.current = document.getElementById(slotId));

            // Same three fields the Stimulus controller sends. Getting this set
            // wrong is silent: the turn still works and the auction quietly
            // changes behaviour, which is why a spec pins these keys across
            // every place the gem documents them.
            const body = {
              session_id: slot.dataset.wavebirdSessionIdValue,
              position: slot.dataset.wavebirdPositionValue,
            };
            // Present only when the slot was rendered async: true. The endpoint
            // reads the delivery mode from the body, so omitting it quietly
            // serves the blocking path.
            if (slot.dataset.wavebirdModeValue) body.mode = slot.dataset.wavebirdModeValue;

            // The hosted renderer refuses the turn without this: startTurn
            // checks authoritative_consent before it fetches anything and
            // returns a null decision, so the endpoint is never called and
            // nothing is logged. The view helper serialises it onto the slot.
            let consent = null;
            try {
              const raw = slot.dataset.wavebirdConsentValue;
              if (raw) consent = JSON.parse(raw);
            } catch { /* a broken consent config costs the ad, never the turn */ }

            // If render.js was blocked or never loaded, run the work unwrapped.
            // The ad path must never break the chat.
            if (!window.wavebird?.withTurn) {
              await work();
              return { slot, wrapped: false };
            }
            const input = { target: slot, body };
            if (consent) input.authoritative_consent = consent;
            await window.wavebird.withTurn(input, work);
            return { slot, wrapped: true };
          }, [slotId]);
        }

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

        // ------------------------------------------------------------------
        // The host app — ordinary React, with no wavebird concepts in it.
        // ------------------------------------------------------------------
        function Chat({ setStatus }) {
          const [messages, setMessages] = useState([]);
          const [draft, setDraft] = useState("");
          const [busy, setBusy] = useState(false);

          const withWavebirdTurn = useWavebirdTurn("wavebird-slot-below");

          const send = useCallback(async (event) => {
            event.preventDefault();
            const message = draft.trim();
            if (!message) return;

            setDraft("");
            setBusy(true);
            setStatus(["<b>turn</b> started, placement requested…"]);

            // Stands in for your real AI endpoint.
            const work = async () => {
              const response = await fetch("/messages", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ message }),
              });
              const data = await response.json();
              // Stored as text and rendered as a React child, never as HTML: a
              // reply is untrusted the moment it comes from a real model.
              setMessages((prev) => [...prev, data.reply]);
            };

            const { slot, wrapped } = await withWavebirdTurn(work);

            // Without this panel an empty slot is ambiguous: a no-fill and a
            // broken integration look identical, the trap that hid #017. Three
            // causes look the same from here -- an honest no-fill, a missing
            // key, and a request wavebird rejected -- so ask the server which it
            // was rather than guessing in the copy.
            const filled = slot.hidden === false;
            setStatus([
              `<b>render.js</b> ${wrapped ? "loaded" : "not loaded — turn ran unwrapped"}`,
              "<b>turn</b> finished, answer delivered",
              filled ? "<b>slot</b> filled — wavebird returned a placement" : await slotReason(),
            ]);
            setBusy(false);
          }, [draft, withWavebirdTurn, setStatus]);

          return html`
            <${React.Fragment}>
              <div className="panel">
                <h2>Conversation</h2>
                <div id="messages">
                  ${messages.map((text, i) => html`<p key=${i}>${text}</p>`)}
                </div>
                <form onSubmit=${send}>
                  <input
                    type="text"
                    value=${draft}
                    placeholder="Ask something…"
                    autoComplete="off"
                    onInput=${(e) => setDraft(e.target.value)} />
                  <button type="submit" disabled=${busy}>Send</button>
                </form>
              </div>
            <//>
          `;
        }

        // Two roots, deliberately. The wavebird slot sits between them in the
        // document and belongs to neither: React never renders into it, so it
        // cannot clobber what the hosted renderer mounts there. That separation
        // is the only structural thing a React host has to get right.
        //
        // A real app would use a context or a store to share this; a module-level
        // subscriber keeps the example to one idea per file.
        function App() {
          const [status, setStatus] = useState(["Send a message to start a turn."]);

          return html`
            <${React.Fragment}>
              ${createPortal(html`<${Chat} setStatus=${setStatus} />`, chatRoot)}
              ${createPortal(html`<${Status} lines=${status} />`, statusRoot)}
            <//>
          `;
        }

        function Status({ lines }) {
          // The status strings are written above in this file, never from the
          // server or the model, so the <b> tags in them are ours.
          return html`<p id="status" dangerouslySetInnerHTML=${{ __html: lines.join("<br>") }} />`;
        }

        const chatRoot = document.getElementById("chat-root");
        const statusRoot = document.getElementById("status-root");

        // One React tree, portalled into two places, so state is shared without
        // a store and the slot between them is left completely alone.
        createRoot(document.createElement("div")).render(html`<${App} />`);
      </script>
    </body>
  </html>
ERB
# rubocop:enable Style/RedundantHeredocDelimiterQuotes

port = ENV.fetch("PORT", 3000).to_i
puts "\n  wavebird-rails — chat WITH React (no build step) -> http://localhost:#{port}"
puts "  #{Wavebird::ExampleCredentials.summary}\n\n"

# Puma's server API directly rather than a Rack handler: the handler namespace
# moved between rack 2, rack 3 and the extracted rackup gem.
server = Puma::Server.new(Rails.application)
server.add_tcp_listener("127.0.0.1", port)
server.run
sleep
# rubocop:enable Style/OneClassPerFile
