# Installing wavebird-rails in a host app

This guide covers the browser half of the integration. The server half (the
mounted engine, the `create_placement` call, credentials) is covered in the
README.

There are two ways to bring a slot alive, and **most apps want the first one.**

| | Setup | Use it when |
|---|---|---|
| **[Plain JavaScript](#the-short-path--plain-javascript)** | render-script tag, a slot, one call | Almost always. No importmap pins, no Stimulus registration, no asset load path |
| **[Stimulus controller](#the-stimulus-path)** | the above, plus 2 pins, an asset path and a controller registration | You want turns dispatched as DOM events, or the controller's async Turbo Stream handling |

Both end up calling the same `window.wavebird.withTurn(...)` from the hosted
`render.js`, and both **degrade silently**: if `render.js` never loads, the slot
stays hidden and your chat turn runs untouched.

The Stimulus path is not the more capable one — it is the more *convenient* one
if your front end is already event-driven. Everything it does, including sending
your stable session id, the plain path can do in one extra line.

---

# The short path — plain JavaScript

Three steps, matching wavebird's own integration brief.

**1. Let your views use the helpers** (once, in `app/controllers/application_controller.rb`):

```ruby
class ApplicationController < ActionController::Base
  helper Wavebird::SlotHelper
end
```

**2. Render the script tag and a slot:**

```erb
<%= wavebird_render_script_tag %>

<%= wavebird_slot endpoint: wavebird.sponsor_slot_path,
                  session_id: wavebird_session_id,
                  position: "below" %>
```

**3. Wrap your chat turn:**

```js
const slot = document.querySelector("#wavebird-slot-below");

window.wavebird.withTurn(
  {
    target: slot,
    body: {
      session_id: slot.dataset.wavebirdSessionIdValue,
      position: slot.dataset.wavebirdPositionValue,
    },
  },
  () => sendChatMessage(message),
);
```

That is the whole integration. No importmap pins, no asset load path, no
Stimulus.

**Why the options object rather than the one-liner.** `withTurn` also takes a
bare selector:

```js
window.wavebird.withTurn("#wavebird-slot-below", () => sendChatMessage(message));
```

which is shorter but uses `render.js`'s **default body — a fresh random session
id per turn**. Passing `body` explicitly sends the stable
`wavebird_session_id` your app already has, which is what keeps a visitor's turns
attributable to one session. The slot element carries both values as data
attributes for exactly this reason, so no extra plumbing is needed. (The
behaviour is pinned by a spec against the dated `render.js` snapshot, so an
upstream change cannot silently downgrade it.)

**If `render.js` might not have loaded yet**, guard on it — your chat turn must
never depend on the ad path:

```js
const send = () => sendChatMessage(message);
if (window.wavebird?.withTurn) {
  window.wavebird.withTurn({ target: slot, body: { /* … */ } }, send);
} else {
  send();
}
```

---

# The Stimulus path

Everything above still applies; this adds a controller that dispatches turns as
DOM events and handles the async Turbo Stream mode. Skip it unless you want that.

The gem ships two JavaScript files under `app/javascript/`:

| File | Purpose |
|------|---------|
| `controllers/wavebird_controller.js` | the Stimulus controller |
| `wavebird/index.js` | `registerWavebirdControllers(application)` helper |

Pick the section matching your app's JavaScript setup.

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

## The slot markup

Unchanged from the short path — the same `wavebird_slot` call emits a hidden
`<section data-controller="wavebird" ...>`, which is what the registered
controller attaches to:

```erb
<%= wavebird_render_script_tag %>

<%= wavebird_slot endpoint: wavebird.sponsor_slot_path,
                  session_id: wavebird_session_id,
                  position: "below" %>
```

`wavebird_render_script_tag` loads `render.js` for you; the controller also loads
it as a fallback, so the tag is optional but recommended (it lets the browser
start fetching the script earlier).

---

## Wiring your chat turn through the controller

Dispatch a DOM event on the slot element (or any descendant), carrying the work
to run as `detail.work`. The controller wraps it in a wavebird turn and injects
the slot's stable `session_id` automatically — this is the convenience the
Stimulus path buys you over building the body yourself:

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

Calling `window.wavebird.withTurn(...)` directly still works on a Stimulus slot —
the two do not conflict, and the plain form from
[the short path](#the-short-path--plain-javascript) is the escape hatch when a
particular turn needs a body the controller does not build.

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
Turbo Stream). **Async mode needs a `session_id:`** — the stream is scoped to it,
so a decision reaches only the visitor it belongs to rather than everyone viewing
that slot position. Omit it and the slot logs a warning and renders in the
blocking default instead: still works, just without the latency saving.

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
