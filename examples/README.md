# Examples

Two, covering the two ways to wire a turn. Start with the first.

## [`single_file_chat.rb`](single_file_chat.rb) — run it

A complete integration in one file: engine mounted, initializer, helper opt-in,
slot, and turn wiring. No `rails new`, no database, no build step, no importmap.

```sh
bundle exec ruby examples/single_file_chat.rb   # from a clone of this repo
open http://localhost:3000
```

It runs **without a wavebird key** — the client is fail-silent, so an
unconfigured key yields a no-fill: the slot stays hidden and the chat still
works. Running it unconfigured is the fastest way to see that the ad path cannot
break your app. For real sandbox placements:

```sh
WAVEBIRD_SECRET_KEY=sk_test_... WAVEBIRD_CLIENT_ID=wbproj_... \
  bundle exec ruby examples/single_file_chat.rb
```

This one uses the **plain-JavaScript path** — `window.wavebird.withTurn(...)`
called directly, which is what [INSTALL.md](../INSTALL.md) leads with and what
most apps should use.

## [`chat_with_sponsored_slot/`](chat_with_sponsored_slot/) — where the files go

The same integration split across the files a real app puts them in — an
initializer, routes, `ApplicationController`, a controller, a view. Not runnable
on its own; copy the pieces into a `rails new` app.

Use it for two things the single-file version cannot show: **where each piece
belongs** in a conventional Rails layout, and the **Stimulus path** — dispatching
a `wavebird:turn` DOM event instead of calling the global. That path costs two
importmap pins, an asset load path entry and a controller registration, and buys
convenience rather than capability. See
[INSTALL.md](../INSTALL.md#the-stimulus-path).
