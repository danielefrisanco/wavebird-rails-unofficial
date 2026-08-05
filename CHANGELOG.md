# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - unreleased

First release: a Ruby/Rails port of the public
[wavebird TypeScript SDK](https://github.com/wavebird-ai/wavebird), targeting
wavebird's canonical REST v1 API.

### Added

#### API client

- `Wavebird::Client` — Faraday-based client for the canonical v1 endpoints:
  `#create_placement` (`POST /v1/placements`), `#create_job` (`POST /v1/jobs`),
  `#decision` and `#await_decision` (`GET /v1/decisions/{slot_id}`),
  `#record_beacon` (`POST /v1/beacons`), `#report_generation`
  (`POST /v1/jobs/{job_id}/generation/{event}`), `#record_consent`
  (`POST /v1/consent`), `#activate_browser` (`POST /v1/browser/activate`) and
  `#project_config` (`GET /v1/projects/{client_id}/config`). Raises typed errors;
  a no-fill is a first-class success, never an exception.
- `#await_decision` ports the upstream polling ladder exactly: two long polls,
  then short polls with ×1.5 backoff capped at 2 s plus jitter, bounded by
  `decision_timeout_ms`. Failed polls are reported and polling continues.
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

#### Documentation and tooling

- `README.md` with quickstart, full public API reference, credential-class table
  and the privacy rules the gem enforces; `INSTALL.md` covering importmap and
  bundler setups; `examples/chat_with_sponsored_slot/` as a copy-pasteable
  integration.
- YARD documentation on the entire public API, gated by `rake yard_coverage`.
- RSpec suite at 100 % line and branch coverage over `lib/`, plus Capybara system
  specs driving the browser glue in headless Chrome against a dummy host app.
- `docs/parity.md` (field-by-field parity with the TypeScript SDK) and
  `docs/DECISIONS.md` (the ported-behavior decisions and their rationale).

[Unreleased]: https://github.com/danielefrisanco/wavebird-rails/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/danielefrisanco/wavebird-rails/releases/tag/v0.1.0
