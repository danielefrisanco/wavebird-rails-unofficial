# Example: chat with a sponsored slot

A minimal end-to-end integration — the Rails equivalent of the Next.js example
in wavebird's integration brief. Four files, mirroring where they go in a host
app:

```
config/initializers/wavebird.rb      credentials + defaults
config/routes.rb                     mount the engine
app/controllers/application_controller.rb   helper opt-in + session id
app/controllers/chats_controller.rb  your chat surface (nothing wavebird-specific)
app/views/chats/show.html.erb        the slot + the turn wiring
```

Copy them into a fresh `rails new` app, add your keys, and register the Stimulus
controller as described in [INSTALL.md](../../INSTALL.md).

## What happens on a send

1. The browser dispatches `wavebird:turn` on the slot element, carrying your
   chat send as `detail.work`.
2. The gem's Stimulus controller hands it to `window.wavebird.withTurn(...)`,
   which POSTs to `/wavebird/sponsor_slot` while your AI answer generates.
3. That endpoint calls wavebird **server-side** (your secret key never leaves the
   server) and returns a browser-safe payload.
4. On a fill, the hosted renderer reveals the slot and mounts its frame. On a
   no-fill the slot stays hidden.
5. **Your chat turn completes either way** — including when wavebird is down, or
   when `render.js` is blocked and never loads.

## Trying it without a wavebird account

Nothing here needs a key to *run* — with an unconfigured or invalid key the
fail-silent client returns a no-fill, the slot stays hidden, and the chat flow
works. That is the intended failure mode, so it is also the easiest way to
confirm the integration cannot break your app.

With an `sk_test_...` sandbox key you get real sandbox placements.

## Async delivery

To resolve the placement in a background job instead of inline, pass
`async: true` to `wavebird_slot` (one word — the controller and endpoint pick it
up from there) and make sure your app has ActiveJob and Turbo Streams. If either
is missing the endpoint logs a warning and falls back to the blocking path, so
the change is safe to make before the infrastructure exists. See
[INSTALL.md](../../INSTALL.md#async-delivery-mode-optional).
