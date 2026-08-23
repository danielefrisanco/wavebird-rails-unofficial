# frozen_string_literal: true

# Being one file is the point of this example, so the usual one-class-per-file
# rule does not apply to it.
# rubocop:disable Style/OneClassPerFile

# wavebird-rails **with Hotwire** — Stimulus turn bridge plus async delivery over
# a Turbo Stream, in one runnable file.
#
#   bundle exec ruby examples/chat_hotwire.rb      # from a clone of this repo
#   open http://localhost:3000
#
# The counterpart without Hotwire is examples/chat_plain.rb. Compare them: this
# one dispatches a `wavebird:turn` DOM event instead of calling
# `window.wavebird.withTurn(...)`, and resolves the placement in a background job
# rather than inline.
#
# Two things a real app gets from its own toolchain are inlined here so the file
# stays runnable: Stimulus comes from a CDN import map rather than
# importmap-rails, and the wavebird controller is loaded from the gem's own
# app/javascript. In your app you would pin both — see INSTALL.md.
#
# Runs **without a wavebird key**: the fail-silent client produces a no-fill, the
# slot stays hidden, the chat still works. For real sandbox placements:
#
#   WAVEBIRD_SECRET_KEY=sk_test_... WAVEBIRD_CLIENT_ID=wbproj_... \
#     bundle exec ruby examples/chat_hotwire.rb

require "action_controller/railtie"
require "action_cable/engine"
require "active_job/railtie"
require "turbo-rails"
require "puma"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
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

Wavebird.configure do |config|
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

# The whole Rails app. Async delivery needs ActiveJob and Turbo Streams over
# ActionCable; both run in-process here so the file needs no Redis.
class ChatHotwireDemo < Rails::Application
  config.root = __dir__
  config.eager_load = false
  config.consider_all_requests_local = true
  config.secret_key_base = "single_file_example_not_a_real_secret"
  config.hosts.clear
  config.logger = Logger.new($stdout)
  config.log_level = :warn
  # Inline so the poll job runs without a separate worker process. A real app
  # uses its own queue adapter; the gem does not care which.
  config.active_job.queue_adapter = :inline
  config.action_cable.cable = { "adapter" => "async" }
  config.action_cable.disable_request_forgery_protection = true
end

Rails.application.initialize!

Rails.application.routes.draw do
  mount Wavebird::Engine => "/wavebird"
  mount ActionCable.server => "/cable"
  root "chats#show"
  post "/messages", to: "chats#reply"
  # Example-only: lets the status panel report why a slot is empty. Not part of
  # the gem, and not something to copy into a real app.
  get "/demo/diagnostics", to: "chats#diagnostics"
  # Serves the gem's Stimulus controller straight from its app/javascript, so
  # this file needs no asset pipeline. A real app pins it instead.
  get "/wavebird_controller.js", to: "chats#controller_js"
end

# The host controller. The two wavebird lines are the same on both paths —
# Hotwire changes how the turn is dispatched in the browser, not the server side.
class ChatsController < ActionController::Base
  helper Wavebird::SlotHelper
  include Wavebird::SessionId

  def show
    render inline: TEMPLATE, layout: false
  end

  def reply
    sleep 2
    render json: { reply: "You said: #{params[:message]}" }
  end

  # Example-only. See Wavebird::ExampleDiagnostics.
  def diagnostics
    render json: { last_error: Wavebird::ExampleDiagnostics.take }
  end

  # The gem's shipped Stimulus controller, served as-is.
  def controller_js
    path = Wavebird::Engine.root.join("app/javascript/controllers/wavebird_controller.js")
    render plain: File.read(path), content_type: "text/javascript"
  end
end

# rubocop:disable Style/RedundantHeredocDelimiterQuotes
TEMPLATE = <<~'ERB'
  <!doctype html>
  <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>wavebird-rails — chat with Hotwire</title>
      <%= turbo_include_tags %>
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

      <%# Stimulus from a CDN so this file needs no importmap-rails. %>
      <script type="importmap">
        {
          "imports": {
            "@hotwired/stimulus": "https://cdn.jsdelivr.net/npm/@hotwired/stimulus@3.2.2/dist/stimulus.js",
            "controllers/wavebird_controller": "/wavebird_controller.js"
          }
        }
      </script>
    </head>
    <body>
      <main>
        <h1>Chat, with Hotwire</h1>
        <p class="lede">
          The turn is handed over as a <code>wavebird:turn</code> DOM event, and the
          placement resolves in a background job — revealed over a Turbo Stream
          rather than blocking the answer.
        </p>

        <div class="panel">
          <h2>Conversation</h2>
          <div id="messages"></div>
          <form id="composer">
            <input type="text" name="message" placeholder="Ask something…" autocomplete="off">
            <button type="submit">Send</button>
          </form>
        </div>

        <%= wavebird_render_script_tag %>

        <%#
          async: true resolves the placement in a DecisionPollJob and reveals the
          slot over a Turbo Stream scoped to this session. It degrades to the
          blocking path on its own if ActiveJob or Turbo Streams are missing.
        %>
        <%= wavebird_slot endpoint: wavebird.sponsor_slot_path,
                          session_id: wavebird_session_id,
                          position: "below",
                          async: true %>

        <div class="panel">
          <h2>What just happened</h2>
          <p id="status">Send a message to start a turn.</p>
        </div>
      </main>

      <script type="module">
        import { Application } from "@hotwired/stimulus";
        import WavebirdController from "controllers/wavebird_controller";

        // The two lines INSTALL.md's Stimulus path asks for.
        const application = Application.start();
        application.register("wavebird", WavebirdController);

        const composer = document.querySelector("#composer");
        const button   = composer.querySelector("button");
        const input    = composer.querySelector("input");
        const messages = document.querySelector("#messages");
        const status   = document.querySelector("#status");
        const slot     = document.querySelector("#wavebird-slot-below");

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
                     "This is a real failure, not an empty auction and not a pending stream. " +
                     "The chat was unaffected.";
            }
          } catch {
            // Diagnostics are a convenience; never let them break the panel.
          }
          return "<b>slot</b> hidden — no-fill, or the async decision is still in flight and will " +
                 "arrive over the Turbo Stream. Either way the chat was never blocked.";
        }

        async function sendChatMessage(message) {
          const response = await fetch("/messages", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ message }),
          });
          const data = await response.json();
          const line = document.createElement("p");
          line.textContent = data.reply;
          messages.appendChild(line);
        }

        composer.addEventListener("submit", (event) => {
          event.preventDefault();
          const message = input.value.trim();
          if (!message) return;
          input.value = "";
          button.disabled = true;

          report([
            `<b>mode</b> ${slot.dataset.wavebirdModeValue || "blocking"}`,
            "<b>turn</b> dispatched as a wavebird:turn event…",
          ]);

          // The Stimulus path: dispatch, and the controller wraps the work in
          // withTurn and builds the request body (session id, position, mode)
          // from its own values. `done` is how a fire-and-forget dispatch learns
          // the turn finished.
          slot.dispatchEvent(new CustomEvent("wavebird:turn", {
            detail: {
              work: () => sendChatMessage(message),
              done: async () => {
                // In async mode an empty slot has one more cause than the
                // blocking examples: the decision may still be in flight over
                // the Turbo Stream. Ask the server whether it *failed* before
                // offering that reassurance, or a rejected request reads as
                // "any moment now" forever.
                const filled = slot.hidden === false;
                report([
                  `<b>mode</b> ${slot.dataset.wavebirdModeValue || "blocking"}`,
                  "<b>turn</b> finished, answer delivered",
                  filled ? "<b>slot</b> filled" : await slotReason(),
                ]);
                button.disabled = false;
                input.focus();
              },
            },
          }));
        });
      </script>
    </body>
  </html>
ERB
# rubocop:enable Style/RedundantHeredocDelimiterQuotes

port = ENV.fetch("PORT", 3000).to_i
puts "\n  wavebird-rails — chat WITH Hotwire -> http://localhost:#{port}"
puts "  #{Wavebird::ExampleCredentials.summary}\n\n"

server = Puma::Server.new(Rails.application)
server.add_tcp_listener("127.0.0.1", port)
server.run
sleep
# rubocop:enable Style/OneClassPerFile
