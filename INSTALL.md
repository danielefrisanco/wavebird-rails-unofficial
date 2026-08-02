# Installing wavebird-rails in a host app

This guide covers the browser half of the integration — registering the
`wavebird` Stimulus controller so a sponsor slot rendered by the `wavebird_slot`
view helper comes alive. The server half (the mounted engine, the
`create_placement` call, credentials) is covered in the README.

The controller loads the hosted `render.js` once per page and bridges your chat
turn into `window.wavebird.withTurn(...)`. It **degrades silently**: if
`render.js` never loads, the slot simply stays hidden and your chat turn runs
untouched.

The gem ships two JavaScript files under `app/javascript/`:

| File | Purpose |
|------|---------|
| `controllers/wavebird_controller.js` | the Stimulus controller |
| `wavebird/index.js` | `registerWavebirdControllers(application)` helper |

Pick the section matching your app's JavaScript setup.

---

## Option 1 — importmap-rails (the Rails 7+ default)

1. **Pin the gem's JS.** In `config/importmap.rb`:

   ```ruby
   pin "controllers/wavebird_controller", to: "controllers/wavebird_controller.js"
   pin "wavebird", to: "wavebird/index.js"
   ```

   For importmap to find those files, add the gem's JS directory to the asset
   load path in `config/initializers/assets.rb` (or an initializer of your own):

   ```ruby
   Rails.application.config.assets.paths << Wavebird::Engine.root.join("app/javascript")
   ```

2. **Register the controller** where you start Stimulus (usually
   `app/javascript/controllers/index.js` or `application.js`):

   ```js
   import { Application } from "@hotwired/stimulus";
   import { registerWavebirdControllers } from "wavebird";

   const application = Application.start();
   registerWavebirdControllers(application);
   ```

   If you use `stimulus-loading`'s eager/lazy autoloading, you can instead let it
   discover `controllers/wavebird_controller` on its own — but the explicit
   `registerWavebirdControllers(application)` call is the setup-independent path.

---

## Option 2 — jsbundling-rails (esbuild / rollup / webpack) or a Node build

1. **Make the gem's JS resolvable.** The files live inside the installed gem, so
   point your bundler at them. The simplest approach is to copy them into your
   app's JS tree once (they have no build-time dependencies beyond
   `@hotwired/stimulus`, which your app already has):

   ```bash
   cp "$(bundle show wavebird-rails)/app/javascript/controllers/wavebird_controller.js" \
      app/javascript/controllers/
   ```

   Or add the gem path as a resolve root in your bundler config if you prefer not
   to vendor the file.

2. **Register the controller** in your Stimulus entrypoint:

   ```js
   import { Application } from "@hotwired/stimulus";
   import WavebirdController from "./controllers/wavebird_controller";

   const application = Application.start();
   application.register("wavebird", WavebirdController);
   ```

---

## Using the slot in a view

The engine isolates its namespace, so its view helpers are not mixed into your
app's views automatically. Opt in once:

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  helper Wavebird::SlotHelper
end
```

Then render a slot and the render-script tag:

```erb
<%= wavebird_render_script_tag %>

<%= wavebird_slot endpoint: wavebird.sponsor_slot_path,
                  session_id: wavebird_session_id,
                  position: "below" %>
```

This emits a hidden `<section data-controller="wavebird" ...>`. The
`wavebird_render_script_tag` helper loads `render.js` for you; the controller
also loads it as a fallback, so the tag is optional but recommended (it lets the
browser start fetching the script earlier).

---

## Wiring your chat turn

There are two ways to hand your chat send/generate function to wavebird. Both
end up calling `window.wavebird.withTurn(...)` around your work. Pick whichever
fits your front end — you do not need both.

### Path A — dispatch a `wavebird:turn` event (Stimulus-idiomatic)

Dispatch a DOM event on the slot element (or any descendant), carrying the work
to run as `detail.work`. The controller wraps it in a wavebird turn and injects
the slot's stable `session_id` automatically:

```js
const slot = document.querySelector("#wavebird-slot-below");

slot.dispatchEvent(new CustomEvent("wavebird:turn", {
  detail: { work: () => sendChatMessage(message) },
}));
```

To await the turn from a host that dispatched fire-and-forget, pass a `done`
callback in `detail` — it is invoked as `done(error, value)`:

```js
slot.dispatchEvent(new CustomEvent("wavebird:turn", {
  detail: {
    work: () => sendChatMessage(message),
    done: (error, value) => { if (!error) console.log("turn done", value); },
  },
}));
```

If `window.wavebird` has not loaded, the controller still runs `detail.work()`
unwrapped, so your chat turn is never blocked.

### Path C — call the global directly (faithful to the vendor SDK)

Exactly as the wavebird integration brief documents — no Stimulus coupling:

```js
window.wavebird.withTurn("#wavebird-slot-below", () => sendChatMessage(message));
```

Guard on availability if `render.js` may not have loaded yet:

```js
const send = () => sendChatMessage(message);
if (window.wavebird?.withTurn) {
  window.wavebird.withTurn("#wavebird-slot-below", send);
} else {
  send();
}
```

Note: path C uses `render.js`'s default request body (a random session id per
turn). To send your app's **stable** `wavebird_session_id`, use path A, which
injects it from the slot's Stimulus value.

---

## Async delivery mode (optional)

By default the slot fills **synchronously**: the browser POSTs, the server waits
`wait_ms` for the decision, and the response comes back inline. This needs
nothing beyond the setup above.

**Async mode** instead returns immediately and reveals the slot a moment later
over a Turbo Stream, so the chat turn adds zero latency. It is opt-in and leans
on two components your app most likely already has:

- **ActiveJob** (with any adapter — Sidekiq, SolidQueue, etc.) runs the poll job.
- **Turbo Streams over ActionCable** (`turbo-rails` + a `config/cable.yml`
  adapter) delivers the reveal to the browser.

These are **optional runtime requirements**, not gem dependencies: if either is
missing, the endpoint logs a warning and transparently falls back to the
synchronous path — the slot still fills, so nothing breaks.

To enable it, render the slot with `async: true` (which also subscribes it to its
Turbo Stream) and post `mode: "async"` from your turn:

```erb
<%= wavebird_render_script_tag %>
<%= wavebird_slot endpoint: wavebird.sponsor_slot_path,
                  session_id: wavebird_session_id,
                  position: "below",
                  async: true %>
```

```js
// dispatch the turn with mode: async in the request body
slot.dispatchEvent(new CustomEvent("wavebird:turn", {
  detail: { work: () => sendChatMessage(message) },
}));
```

The background job broadcasts only browser-safe fields — the asset token is
folded into `frame_url` **on the server** and never reaches the browser, exactly
as in the synchronous path. Set the job's queue with
`Wavebird.configure { |c| c.async_queue_name = :low_priority }` if desired.

## Verifying

- The AI response still appears when wavebird is unavailable (block `render.js`
  in devtools and confirm the chat turn completes).
- The sponsored slot stays hidden on a no-fill decision.
- A filled placement renders inside the `<section>`, never inside your answer
  text.
- The secret key never appears in the browser (it lives only server-side in the
  engine controller).
