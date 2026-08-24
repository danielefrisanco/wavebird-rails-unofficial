# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

**Versions track the upstream SDK this gem ports, not an independent cadence.**
`0.1.5` here implements the contract of wavebird TypeScript SDK `0.1.5`; it does
not mean five patch releases of this gem. That is a deliberate trade: it gives up
semantic versioning of our own changes in exchange for making the answer to
"which SDK does this implement?" obvious from the version alone.

## [Unreleased]

## [0.1.5] - unreleased

First release: a Ruby/Rails port of the public
[wavebird TypeScript SDK](https://github.com/wavebird-ai/wavebird), targeting
wavebird's canonical REST v1 API.

### Added

#### API client

- `Wavebird::Client` — Faraday-based client for the canonical v1 endpoints:
  `#create_placement` (`POST /v1/placements`, with the same `topic:`/`locale:`
  hints as the jobs route — both verified accepted by the API),
  `#create_job` (`POST /v1/jobs`),
  `#await_decision` and `#poll_decision_once` (`GET /v1/decisions/{slot_id}`),
  `#record_beacon` (`POST /v1/beacons`), `#report_generation`
  (`POST /v1/jobs/{job_id}/generation/{event}`), `#record_consent`
  (`POST /v1/consent`), `#activate_browser` (`POST /v1/browser/activate`) and
  `#project_config` (`GET /v1/projects/{client_id}/config`). Raises typed errors;
  a no-fill is a first-class success, never an exception.
- `#await_decision` ports the upstream polling ladder exactly: two long polls,
  then short polls with ×1.5 backoff capped at 2 s plus jitter, bounded by
  `decision_timeout_ms`. Failed polls are reported and polling continues. It is
  the equivalent of the SDK's `getDecision`; `#poll_decision_once` is a single
  request, named so it cannot be mistaken for it (#026).
- `Wavebird::Facade` (what `Wavebird.client` returns) — the fail-silent layer
  that restores the upstream SDK's posture: every failure is reported through
  `on_error`/`logger` and returned as a "hide the slot and continue" value, so a
  wavebird outage is indistinguishable from an empty auction and never breaks the
  host flow. It mirrors the whole `Client` surface, and its fallbacks are
  upstream's own: a pending decision when the polling budget runs out,
  `{accepted: false, reason_code: "SDK_FAIL_SILENT"}` for a beacon, `false` for
  `report_generation`, and `Types::RateLimited` — logged at `warn`, never through
  `on_error` — when job creation is throttled.
- `Wavebird::DecisionNormalizer` — port of upstream `normalizeV1Decision`,
  including its validation rules and creative defaults.
- `Wavebird::Deprecation` — port of upstream `warnSdkDeprecation`: announces a
  deprecation once per process through `config.logger`. Drives the warning for
  `overrides.timing: "before"`/`"after"`, whose recommended value is `"during"`.
- `Wavebird::Types` value objects mirroring the upstream public contracts
  field-for-field: `PlacementResponse` (null placement = first-class no-fill),
  `Placement`, `Render`, `Decision`, `Creative`, `NativeAssets`, `AcceptedJob`,
  `RateLimited` (the other branch of upstream's `JobResponse` union, discriminated
  by `rate_limited?`), `BeaconResult`, `ConsentState`, `BrowserActivation`,
  `ProjectConfig`. Tolerant
  reads (unknown fields kept in `raw`), with `asset_token`/`frame_url` redacted
  from all inspection output.
- `Wavebird::Configuration` + `Wavebird.configure` — defaults and numeric
  clamping mirroring the upstream SDK (`timeout_ms`, `decision_timeout_ms`,
  `long_poll_wait_ms`, `short_poll_interval_ms`), HTTPS-except-localhost base URL
  validation, callable secret keys, and secret redaction in `inspect`.
- Errors keep the API's **diagnostic** envelope fields — `reason_code`, `hint`,
  `expected_shape` and `fields` — alongside the documented ones.
  `#diagnostic_message` renders them together, and is what `on_error` and the
  gem's logging use. wavebird does not document these, but a 400 whose `message`
  says only "check the request body schema" routinely carries a `reason_code`
  that names the cause exactly (#032).
- `Wavebird::Error` hierarchy — typed exceptions per API error code
  (`unauthorized`, `forbidden`, `rate_limited` with `retry_after`,
  `validation_error`, `not_found`), transport errors, and
  `request_id`/`docs_url`/`http_status` on every error.
- `ActiveSupport::Notifications` instrumentation on `wavebird.request`, carrying
  only method, path, status and error — never credentials or asset tokens.

#### Rails integration

- `Wavebird::Engine` — isolated engine providing `POST /wavebird/sponsor_slot`.
- `Wavebird::SponsorSlotsController` — the server-side endpoint the browser posts
  slot context to. Calls wavebird with the secret key server-side only and
  returns a browser-safe payload; any failure renders as a plain no-fill.
- `Wavebird::SlotHelper` — `wavebird_slot` (a hidden `<section>` the hosted
  renderer owns, not a Turbo Frame) and `wavebird_render_script_tag` (emitted
  once per page).
- `Wavebird::SessionId` — controller concern providing an anonymous, stable
  `sess_...` token per browser session. Never a user identifier.
- Stimulus controller (`app/javascript/controllers/wavebird_controller.js`)
  bridging a host's chat turn into `window.wavebird.withTurn(...)`. Two
  documented entry points: a `wavebird:turn` DOM event, or calling the vendor
  global directly. Degrades to running the turn unwrapped when the hosted
  renderer is absent.
- **Optional async delivery mode** — `wavebird_slot(async: true)` resolves the
  placement in `Wavebird::DecisionPollJob` and reveals the slot over a Turbo
  Stream, adding no latency to the chat turn. ActiveJob and Turbo/ActionCable are
  optional runtime requirements, lazily loaded; when either is missing the
  endpoint logs a warning and falls back to the blocking path.
- `Wavebird::SlotPayload` — the single browser-safe projection shared by both
  delivery paths. In async mode the server reconstructs `frame_url` from the
  `asset_token` so the bare token never reaches the browser.

#### Security

- **`config.authoritative_consent` — required for any ad to be requested.**
  wavebird's hosted renderer gates every turn (and every beacon) on a consent
  object; without a valid one it returns a null decision without calling the
  host's endpoint at all — no request, no error, nothing in the console. Set a
  callable returning `lifecycle_state` and `expires_at_ms`; it is resolved fresh
  on every slot render, so the gem never stores consent and a withdrawal takes
  effect on the next turn. `revision` and `updated_at_ms` default. A state other
  than `"granted"` is a normal answer and is silent; a malformed object is
  reported through `logger` every time, since the renderer would otherwise reject
  it silently. The check is local to the browser — the object is never sent to
  wavebird — so this is the host's assertion, not wavebird's verification (#030).

- `config.before_send_text` — an egress hook for filtering caller-supplied free
  text (today `topic:`) before it is sent, so a host can wire `data_redactor` or
  their own scrubber without monkey-patching. It receives **one value at a time**,
  never the request body, so it structurally cannot rewrite `client_id`, drop
  `consent`, or inject fields the gem refuses to send. **Fails closed**: a raising
  filter drops the field rather than sending the original, reported through
  `on_error` and logged at `warn` every time. Unset by default. This is the only
  way to filter the engine endpoint, whose caller is inside the gem (#028).

- Async decision streams are **scoped to the session**, not to the slot position.
  A position-only stream is shared by every visitor rendering it, so one
  visitor's decision — including the `frame_url` that embeds their `asset_token`
  — would be delivered to all of them and fire their beacons from unrelated
  browsers. `wavebird_slot(async: true)` needs a `session_id`; without one it
  warns and renders a blocking slot rather than an unscoped stream.
- The sponsor-slot endpoint derives the broadcast stream server-side and no
  longer accepts `stream_name`, `overrides` or `consent` from the browser: those
  steer the auction or assert what wavebird may do with the request, and a page
  is not a trusted source for either. Configure them with
  `config.default_overrides` / `config.default_consent`.
- `Wavebird::Railtie` + `Wavebird::BootCheck` — boot-time guards that raise
  `ConfigurationError` when the gem is required from a browser-reachable tree
  (`app/assets`, `app/javascript`), or when its server-side Ruby lands on the
  asset load path. The gem's own `app/javascript` directory is explicitly
  allowed, since that is the documented importmap setup.
- The client's public API has no parameter for prompts, chat history, user ids or
  other PII, and the server endpoint accepts only a whitelisted slot context from
  the browser.
- Source-level leak audit spec asserting no gem code path interpolates
  `secret_key` or `asset_token` into a string outside a small explicit allowlist.
- The 64 KiB response cap applies to **error envelopes**, not only success
  bodies, so an oversized 4xx/5xx from a misbehaving origin or proxy is rejected
  rather than buffered and parsed. Matches upstream, which enforces the cap in
  the response's `data` handler before any status branching exists; as there, an
  unreadable response wins over the status classification, so an oversized 429
  raises `InvalidResponseError` instead of becoming a rate-limit result.

#### Documentation and tooling

- **React**: a `useWavebirdTurn` hook recipe in `INSTALL.md` and a runnable
  `examples/chat_react.rb` (React + `htm` from a CDN, no build step). The gem
  ships no React code — `window.wavebird.withTurn` is already framework-agnostic,
  so React needs an example rather than a feature. The one structural rule is
  that the slot stays outside the React tree; the example portals one React tree
  into two roots either side of it (#029).
- `README.md` with quickstart, full public API reference, credential-class table
  and the privacy rules the gem enforces; `INSTALL.md` covering importmap and
  bundler setups; `examples/chat_with_sponsored_slot/` as a copy-pasteable
  integration.
- YARD documentation on the entire public API, gated by `rake yard_coverage`.
- RSpec suite at 100 % line and branch coverage over `lib/`, plus Capybara system
  specs driving the browser glue in headless Chrome against a dummy host app.
- `docs/parity.md` (field-by-field parity with the TypeScript SDK) and
  `docs/DECISIONS.md` (the ported-behavior decisions and their rationale).

[Unreleased]: https://github.com/danielefrisanco/wavebird-rails-unofficial/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/danielefrisanco/wavebird-rails-unofficial/releases/tag/v0.1.0
