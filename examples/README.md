# Examples

Two runnable single-file apps, one per integration path, plus the file-by-file
layout for a real host app. Both runnable ones work **without a wavebird key** —
the client is fail-silent, so an unconfigured key gives a no-fill: the slot stays
hidden and the chat still works. Each page has a status panel saying which
happened, so an empty slot is never ambiguous.

For real sandbox placements, prefix either command with
`WAVEBIRD_SECRET_KEY=sk_test_... WAVEBIRD_CLIENT_ID=wbproj_...`.

## [`chat_plain.rb`](chat_plain.rb) — without Hotwire

```sh
bundle exec ruby examples/chat_plain.rb
open http://localhost:3000
```

The path [INSTALL.md](../INSTALL.md) leads with and most apps should use.
`window.wavebird.withTurn(...)` called directly: no importmap, no Stimulus, no
asset pipeline, no build step.

## [`chat_hotwire.rb`](chat_hotwire.rb) — with Hotwire

```sh
bundle exec ruby examples/chat_hotwire.rb
open http://localhost:3000
```

The same integration through Stimulus and Turbo: the turn is dispatched as a
`wavebird:turn` DOM event, and the placement resolves in a background job,
revealed over a **session-scoped** Turbo Stream instead of blocking the answer.

Two things a real app takes from its own toolchain are inlined so the file stays
runnable — Stimulus comes from a CDN import map rather than importmap-rails, and
the gem's controller is served from its own `app/javascript`. In your app you
would pin both; see [INSTALL.md](../INSTALL.md#the-stimulus-path).

Run both side by side (`PORT=3001` on one) to see what Hotwire adds and what it
costs.

## [`chat_with_sponsored_slot/`](chat_with_sponsored_slot/) — where the files go

Not runnable. The same integration split across the files a real app puts them
in — initializer, routes, `ApplicationController`, controller, view. Use it for
the one thing a single file cannot show: where each piece belongs in a
conventional Rails layout.

`rails generate wavebird:install` writes most of these for you.
