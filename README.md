# wavebird-rails

> **Status: pre-release, under active development.** Nothing here is published
> to RubyGems yet; the public API is not stable.

Server-side API client and Hotwire integration for
[wavebird](https://wavebird.ai) — "Compute Sponsoring" ad infrastructure for
AI products. It lets Rails chat apps, copilots and agents show a contextual
sponsored placement alongside an AI-generated response **without sending
prompts, chat history, or user PII to the ad network**.

This gem is a Ruby/Rails port of the original public
[wavebird TypeScript SDK](https://github.com/wavebird-ai/wavebird) (MIT) and
targets wavebird's canonical REST v1 API — the
[official docs](https://wavebird.ai/api) are the source of truth.

## Why it looks the way it does

Three design commitments shape the whole gem:

1. **The secret key never leaves the server.** The browser talks only to *your*
   app; your app talks to wavebird. The gem raises at boot if it is ever wired
   somewhere browser-reachable.
2. **An ad failure is never an app failure.** `Wavebird.client` is fail-silent:
   an outage, timeout or API error is indistinguishable from an honest no-fill,
   so your chat turn always completes and the slot simply stays hidden.
3. **It does not reimplement ad rendering.** It wires your app up to wavebird's
   own hosted renderer (`render.js` + a hosted frame), which is the officially
   recommended "Server API" pattern — and the safest one.

## Install

```sh
bundle add wavebird-rails
```

Then mount the engine and configure your credentials:

```ruby
# config/routes.rb
mount Wavebird::Engine => "/wavebird"
```

```ruby
# config/initializers/wavebird.rb
Wavebird.configure do |c|
  c.secret_key = Rails.application.credentials.dig(:wavebird, :secret_key)
  c.client_id  = Rails.application.credentials.dig(:wavebird, :client_id)  # wbproj_...
  c.logger     = Rails.logger
end
```

The browser half — registering the Stimulus controller for your importmap or
bundler setup — is covered step by step in [INSTALL.md](INSTALL.md).

## Quickstart

The Rails equivalent of the integration brief's Next.js example. Three files.

**1. Opt your views into the slot helpers, and give each browser a stable
anonymous session id.**

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  helper Wavebird::SlotHelper    # the engine isolates its namespace, so opt in explicitly
  include Wavebird::SessionId    # -> wavebird_session_id, also a helper_method
end
```

**2. Render the slot next to your chat.**

```erb
<%# app/views/chats/show.html.erb %>
<%= wavebird_render_script_tag %>

<div id="messages"><%# your AI answers render here %></div>

<%= wavebird_slot endpoint: wavebird.sponsor_slot_path,
                  session_id: wavebird_session_id,
                  position: "below" %>
```

This emits a hidden `<section id="wavebird-slot-below" data-controller="wavebird">`.
Nothing is visible until a placement actually fills.

**3. Hand your chat turn to wavebird.**

```js
const slot = document.querySelector("#wavebird-slot-below");

slot.dispatchEvent(new CustomEvent("wavebird:turn", {
  detail: { work: () => sendChatMessage(message) },
}));
```

The controller wraps your `work` in `window.wavebird.withTurn(...)`, which
requests a placement for the turn while your AI answer generates. On a fill the
slot reveals itself and the hosted frame renders inside it; on a no-fill it stays
hidden. **Either way `sendChatMessage` runs** — including when `render.js` is
blocked or never loads.

If you'd rather not couple to Stimulus, call the global exactly as the vendor
brief documents:

```js
window.wavebird.withTurn("#wavebird-slot-below", () => sendChatMessage(message));
```

A complete, copy-pasteable version of these files — plus the initializer and the
route — lives in
[examples/chat_with_sponsored_slot/](examples/chat_with_sponsored_slot/).

### Optional: async delivery

Pass `async: true` to `wavebird_slot` and the placement resolves in a background
job, revealing the slot over a Turbo Stream — zero added latency on the chat
turn. It needs ActiveJob and Turbo Streams in your app, and **falls back to the
blocking path automatically** if either is missing. See
[INSTALL.md](INSTALL.md#async-delivery-mode-optional).

### Calling the API directly

You don't need any of the Rails glue to use the client:

```ruby
response = Wavebird.client.create_placement(job_type: "chat", session_id: "sess_abc")

if response.fill?
  response.placement.render.frame_url   # hand to the hosted renderer
else
  # no-fill: hide the slot, carry on. Not an error.
end
```

## Public API reference

### Module

| Method | Returns | Notes |
|---|---|---|
| `Wavebird.configure { \|c\| ... }` | `Configuration` | see the table below |
| `Wavebird.configuration` | `Configuration` | the global config |
| `Wavebird.client` | `Facade` | **fail-silent**; the public default |
| `Wavebird.reset_configuration!` | `void` | drops config + memoized client |

### `Wavebird::Facade` — fail-silent (what `Wavebird.client` returns)

Every method swallows `Wavebird::Error`, reports it via `on_error`/`logger`, and
returns a "hide the slot and continue" value. Use this in request paths. The
whole `Client` surface is mirrored here, because upstream's whole surface is
fail-silent — a method available only in its raising form would let the ad path
break your flow.

| Method | Returns | On failure |
|---|---|---|
| `create_placement(**)` | `Types::PlacementResponse` | synthetic no-fill response |
| `create_job(**)` | `Types::AcceptedJob`, `Types::RateLimited`, `nil` | `nil` — except a 429, which returns `Types::RateLimited` (a result, not a failure: logged at `warn`, no `on_error`) |
| `decision(slot_id, **)` | `Types::Decision` | synthetic pending decision |
| `await_decision(slot_id)` | `Types::Decision` | synthetic pending decision (upstream's `fallbackDecision`) |
| `record_beacon(**)` | `Types::BeaconResult` | `accepted: false`, `reason_code: "SDK_FAIL_SILENT"` |
| `report_generation(job_id, event, **)` | `true` | `false` |
| `record_consent(**)` | `Types::ConsentState`, `nil` | `nil` |
| `activate_browser(**)` | `Types::BrowserActivation`, `nil` | `nil` |
| `project_config(**)` | `Types::ProjectConfig`, `nil` | `nil` |

`ArgumentError` is **not** swallowed: an event outside the canonical enum is a
caller bug, not a wavebird failure (upstream's compiler rejects it before the
call is made).

### `Wavebird::Client` — raising (typed errors)

Instantiate directly (`Wavebird::Client.new`) when you want exceptions.

| Method | Endpoint | Notes |
|---|---|---|
| `create_placement(job_type:, wait_ms:, session_id:, locale:, slots_requested:, topic:, slot_hint:, overrides:, publisher:, consent:)` | `POST /v1/placements` | **primary**: creates a job and waits for the first decision |
| `create_job(job_type:, session_id:, locale:, slots_requested:, topic:, slot_hint:, overrides:, publisher:, consent:)` | `POST /v1/jobs` | advanced/compat; returns `slot_id`s without waiting. This route carries consent as `overrides.gdpr_applies` only — other flags are logged, not sent; use `create_placement` for the full object |
| `decision(slot_id, wait_ms:)` | `GET /v1/decisions/{slot_id}` | one poll; `wait_ms: 0` for a short poll |
| `await_decision(slot_id)` | `GET /v1/decisions/{slot_id}` | upstream polling ladder; raises `DecisionTimeoutError` on budget exhaustion |
| `record_beacon(slot_id:, asset_token:, event:, beacon_id:, occurred_at:, metadata:)` | `POST /v1/beacons` | advanced — the hosted renderer already beacons; don't duplicate |
| `report_generation(job_id, event, generation_id:, model_id:, usage_json:, error:)` | `POST /v1/jobs/{job_id}/generation/{event}` | `started\|finished\|failed` |
| `record_consent(decision:, source:, purposes:, session_id:)` | `POST /v1/consent` | optional; per-request `consent:` works without it |
| `activate_browser(origin:, publishable_key:)` | `POST /v1/browser/activate` | secondary — Script Tag / pure-browser pattern only |
| `project_config(client_id:)` | `GET /v1/projects/{client_id}/config` | non-secret runtime config |

### Rails integration

| Object | Purpose |
|---|---|
| `Wavebird::Engine` | mount at any prefix; provides `POST /wavebird/sponsor_slot` |
| `Wavebird::SessionId` | controller concern → `wavebird_session_id` (anonymous `sess_` token) |
| `Wavebird::SlotHelper#wavebird_slot(endpoint:, session_id:, position:, async:, **html)` | the hidden `<section>` the renderer fills |
| `Wavebird::SlotHelper#wavebird_render_script_tag` | loads `render.js`, once per page |
| `Wavebird::SponsorSlotsController` | the server endpoint the browser POSTs to |
| `Wavebird::DecisionPollJob` | async mode's poller + Turbo Stream broadcast |

### Configuration

| Option | Default | Notes |
|---|---|---|
| `secret_key` | — | `String` or a callable resolved before each request |
| `client_id` | — | `wbproj_...` |
| `publishable_key` | — | `pk_...`, only for `activate_browser` |
| `api_base_url` | `https://api.wavebird.ai` | HTTPS enforced except on localhost |
| `timeout_ms` | `2000` | clamped to 250–30 000 |
| `decision_timeout_ms` | `30000` | clamped to 1 000–60 000 |
| `long_poll_wait_ms` | `1500` | clamped to 0–5 000 |
| `short_poll_interval_ms` | `250` | clamped to 100–5 000 |
| `default_slot_hint` | `nil` | e.g. `{ position: "below", max_width: 728, max_height: 90 }` |
| `default_overrides` | `nil` | e.g. `{ allowed_formats: %w[banner native], timing: "during" }` |
| `default_publisher` | `nil` | merged into `overrides.publisher` |
| `default_consent` | `nil` | consent sent by the engine endpoint, which does not accept it from the browser |
| `on_error` | `nil` | callable; receives every swallowed error |
| `logger` | `nil` | warnings only; never receives secrets or asset tokens |
| `async_queue_name` | `:default` | queue for `DecisionPollJob` |
| `wrapper_version` | `wavebird-rails/{VERSION}` | sent as `User-Agent` and `x-csl-wrapper-version` |

Numeric defaults and clamping ranges mirror the TypeScript SDK exactly — see
[docs/parity.md](docs/parity.md).

### Errors

`Wavebird::Error` is the root; every error carries `request_id`, `docs_url` and
`http_status` where the API supplies them.

| Class | Raised when |
|---|---|
| `ConfigurationError` | missing/invalid credentials or config, and the boot-time security guards |
| `ConnectionError` / `TimeoutError` | transport failure |
| `InvalidResponseError` | the response violates the documented contract |
| `DecisionTimeoutError` | `await_decision` exhausts its polling budget |
| `APIError` | base for HTTP error codes below |
| `UnauthorizedError` (401) / `ForbiddenError` (403) | bad or wrong-class key |
| `RateLimitedError` (429) | carries `retry_after` |
| `ValidationError` (422) / `NotFoundError` (404) | |

**A no-fill is never an error.** `decision.fill == false` and a `null` placement
are ordinary successful responses.

## Credential classes

Never mix these. Which key you use is also *how you select dry-run mode* — there
is no request field for it (do not send `production_dry_run`,
`production_billing_dry_run`, `billing_suppressed` or `production_live_approved`;
those are response/diagnostic-only).

| Prefix | Class | Where it may be used | Billable |
|---|---|---|---|
| `sk_test_` | Server Test Key (sandbox) | server only | no |
| `sk_dry_` | Server Production Dry-run Key | server only | no (no payout setup needed) |
| `sk_live_` | Server Production Key | server only | **yes** |
| `pk_` | Browser Publishable Key | browser only — **never** as `secret_key` | n/a |

## Privacy rules the gem enforces

These are wavebird's own product rules, baked in as behavior rather than advice:

- **No prompts, chat history, user ids, emails or account data are ever sent.**
  The client's public API deliberately has no parameter that invites it. The
  closest thing to content is the optional `topic:` on `create_placement` /
  `create_job` — a single coarse hint like `"cloud hosting"`, never the user's
  text. It is a **server-side** argument: the engine endpoint does not accept a
  topic from the browser, so page content cannot reach the ad network by
  accident. To use it, call the client from your own controller, where you know
  what the turn is about.
- **The secret key is unreachable from the browser.** It lives only in your
  server-side config, is never rendered into HTML or JSON, and is redacted from
  `Configuration#inspect`. A boot-time guard raises `ConfigurationError` if the
  gem is required from `app/assets`/`app/javascript`, or if its Ruby ever lands
  on the asset load path.
- **No-fill and failure leave your AI response path untouched.** `Wavebird.client`
  never raises; the browser glue runs your turn even when `render.js` is absent.
- **`asset_token` is sensitive proof material.** It is redacted from every
  instrumentation payload and from all `#inspect` output, and it never crosses to
  the browser as its own field — the server folds it into `frame_url`, which is
  what the hosted renderer needs.

The session id the gem generates is a random anonymous `sess_` token, not a user
identifier.

### Consent flags are yours to send

The gem sends a `consent` object **only when you supply one** — matching the
TypeScript SDK, which injects no defaults either (decision #013). If you send
nothing, wavebird applies its own server-side defaults.

If your app has a CMP, or you simply want to assert the protective values, pass
them explicitly:

```ruby
Wavebird.client.create_placement(
  job_type: "chat",
  session_id: session_id,
  consent: { semantic_targeting: false, prompt_shared: false,
             gdpr_applies: true, consent_source: "publisher_custom" }
)
```

Use `consent_source: "publisher_custom"` when the consent came from your own UI.
`"wavebird_consent"` means the user answered wavebird's own consent dialog — the
gem never renders one, so claiming it would misstate where the consent came from.

For the **engine endpoint**, set them server-side — it deliberately does not
accept `consent` (or `overrides`) from the browser, since a page must not be able
to assert consent on a user's behalf or undo your brand-safety settings:

```ruby
Wavebird.configure do |c|
  c.default_consent   = { semantic_targeting: false, consent_source: "publisher_custom" }
  c.default_overrides = { blocked_categories: %w[gambling] }
end
```

One limit worth knowing: the canonical `POST /v1/jobs` route used by **async
mode** can only carry `gdpr_applies` (upstream folds it into `overrides`). Other
flags are logged and skipped there; send them through the blocking path, whose
`/v1/placements` body takes the full object.

## Development

```sh
bundle install
bundle exec rake              # unit specs + system specs + rubocop + doc coverage
bundle exec rake spec         # fast: unit/request specs only
bundle exec rake spec:system  # Capybara + headless Chrome against spec/dummy
```

Project working agreement: [WAY_OF_WORK.md](WAY_OF_WORK.md).
Design decisions: [docs/DECISIONS.md](docs/DECISIONS.md).
Port parity vs the original SDK: [docs/parity.md](docs/parity.md).

## Credits

This gem wraps and depends on [wavebird](https://wavebird.ai) — see the
[API documentation](https://wavebird.ai/api), which is the canonical source of
truth for the contract. It is a port of the original public
[wavebird TypeScript SDK](https://github.com/wavebird-ai/wavebird) (MIT), and is
not an official wavebird product.

## License

MIT — see [LICENSE.txt](LICENSE.txt).
