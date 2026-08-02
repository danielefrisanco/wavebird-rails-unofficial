# wavebird-rails — Incremental Build Plan

Companion to [wavebird-rails-build-prompt.md](wavebird-rails-build-prompt.md).
Each phase ends in a green test suite and a working (if partial) gem — no phase
depends on a later one. Verification against the upstream TypeScript SDK and
industry-standard quality gates are built into every phase, plus a dedicated
audit phase at the end.

---

## Phase 0 — Pin the upstream contract (verification baseline) — **done**

- [x] Fetch and snapshot the canonical sources into `docs/upstream/` (date-stamped):
  - `https://wavebird.ai/wavebird-api-llm-integration.md` (integration brief)
  - `https://wavebird.ai/api/reference/types`, `/errors`, `/rate-limits`
  - `https://github.com/wavebird-ai/wavebird` → `src/index.ts`, `src/public_contracts.ts`
- [x] Build a **parity table** (`docs/parity.md`): every TS SDK export ↔ planned Ruby
  equivalent ↔ decision (port / adapt / intentionally skip + why). Known rows:
  | TS SDK | Ruby | Decision |
  |---|---|---|
  | `WavebirdClient` | `Wavebird::Client` | port |
  | `createJob()` | `#create_job` | port |
  | `getDecision()` | `#decision(slot_id)` | port |
  | `sendBeacon()` | `#record_beacon` | port (documented as advanced/optional) |
  | `reportGeneration()` | `#report_generation` | **resolved: port in v1** (decision #002) |
  | `getDecisionViaWebSocket()` (WS to wavebird API) | ActiveJob poll + Turbo Stream broadcast instead | adapt (decision #001) — Rails-native async delivery; direct WS to wavebird **deferred to v2** |
  | `public_contracts.ts` types | `Wavebird` value objects | port field-for-field |
  | `WavebirdAd` React / `mountWavebirdAd` | slot `<section>` + Stimulus + hosted renderer (decision #006) | intentionally not ported |
  | `ConsentDialog` | `#record_consent` API only | intentionally not ported (v1) |
- [ ] Re-check `https://wavebird.ai/api/changelog` + `/api/reference/versioning`
  (prompt data was pulled 2026-07-18 — same day, but confirm).

**Gate:** parity table complete; every skipped TS feature has a written rationale.

## Phase 1 — Gem skeleton & tooling — **done**

- [x] `bundle gem wavebird-rails` layout: `wavebird-rails.gemspec`, `lib/wavebird.rb`,
  `lib/wavebird/version.rb`, MIT `LICENSE`, `CHANGELOG.md` (Keep a Changelog), `.gitignore`.
- [x] Gemspec: runtime deps `faraday` (~> 2), `railties` (>= 7.1, < 9);
  `required_ruby_version >= 3.2`; `homepage`/`source_code_uri` → this repo;
  `rubygems_mfa_required = "true"` in metadata.
- [x] Dev tooling: RSpec, WebMock, SimpleCov (min coverage enforced), RuboCop
  (standard style, `.rubocop.yml` committed), `rake` default task = spec + rubocop.
- [ ] GitHub Actions CI: matrix over supported Ruby × Rails (7.1, 7.2, 8.0) via
  `appraisal` or gemfiles; runs rspec + rubocop. **Dev is now on Ruby 3.4.10 +
  Rails 8.1 (decision #007)**; the CI Ruby floor will be pinned when the matrix
  lands (Phase 8) — the gem still declares `>= 3.2` for consumers on older Rails.

**Gate:** `bundle exec rake` green on empty skeleton; CI runs.

## Phase 2 — Configuration + error hierarchy — **done**

- [x] `Wavebird::Configuration`: `secret_key`, `client_id`,
  `api_base_url` (default `https://api.wavebird.ai`), `default_slot_hint`,
  `default_overrides`, `timeout`/`open_timeout`, `logger`. `Wavebird.configure` block +
  `Wavebird.client` memoized accessor; raise `Wavebird::ConfigurationError` on first
  use with blank `secret_key` (not at boot — per prompt §6).
- [x] `Wavebird::Errors` per §3.9: `Wavebird::Error` base exposing `request_id`,
  `code`, `docs_url`, `http_status`; subclasses `UnauthorizedError`, `ForbiddenError`,
  `RateLimitedError` (with `retry_after`), `ValidationError` (with field paths),
  `NotFoundError`, plus `APIError` fallback for unknown codes and
  `ConnectionError`/`TimeoutError` for transport failures.
- [x] `secret_key` redacted from `Configuration#inspect` / logging.

**Tests:** config defaults, blank-key raise, every error class carries `request_id`.

## Phase 3 — Value objects (`types.rb`) — **done**

- [x] `Data`/`Struct` value objects mirroring `public_contracts.ts` field names exactly:
  `Placement` (incl. nested `Render` with `strategy`, `frame_url`, `script_url`),
  `Decision` (`fill`, `format`, `asset_token`, `assets`), `PlacementResponse`
  (`slot_id`, `status`, `placement` may be nil, `decision`), `BeaconResult`,
  `ConsentState`, `ProjectConfig`.
- [x] Tolerant deserialization: unknown response fields ignored (esp. beacons — §3.6),
  accessible via a raw-attributes reader; never raise on missing optional fields.
- [x] Convenience: `PlacementResponse#fill?` (true only when placement present AND
  `decision.fill`), `#no_fill?` — no-fill is a first-class success state.
- [x] `asset_token` redacted in `#inspect`/`#to_s` of every object carrying it (§4).

**Tests:** round-trip from the exact JSON fixtures in §3.1; nil placement; unknown
fields tolerated; `inspect` never leaks `asset_token`.

## Phase 4 — HTTP client, endpoint by endpoint — **done**

Build on Faraday with WebMock-stubbed tests per endpoint before moving to the next:

- [x] Shared plumbing: `Authorization: Bearer`, JSON encode/decode, `User-Agent:
  wavebird-rails/x.y.z`, error-envelope → exception mapping, `X-Request-Id` capture,
  timeouts, never send `production_dry_run`/`billing_suppressed`/etc. (response-only
  fields, §3). No retry-on-failure by default for placements (latency-sensitive).
- [x] 4.1 `#create_placement(session_id:, job_type: "chat", slots_requested: 1,
  slot_hint:, overrides:, consent:, wait_ms: 1500)` — keyword-args-only, so there is
  no slot for prompts/PII to sneak in (§4); merges configured defaults.
- [x] 4.2 `#create_job(...)` — parity route, documented as advanced.
- [x] 4.3 `#decision(slot_id)` — poll after `/v1/jobs` or placement timeout.
  (Also `#await_decision` — the full polling ladder, decision #001.)
- [x] 4.4 `#record_beacon(beacon_id:, slot_id:, asset_token:, event:, metadata: nil)` —
  generates `occurred_at` **at call time** internally (prevents `BEACON_TOO_LATE`);
  validates `event` against the seven allowed values (decision #005); documented as escape hatch.
- [x] 4.5 `#record_consent(session_id:, decision:, source:, purposes:)` — validate
  enums (decision #005); accept alias sources (`publisher`, `custom_dialog`) but emit only canonical.
- [x] 4.6 `#activate_browser(publishable_key:, origin:)` — secondary, marked as such.
- [x] 4.7 `#project_config` — GET config.
- [x] Also `#report_generation` (decision #002, port in v1).
- [x] Instrumentation: `ActiveSupport::Notifications` (`wavebird.request`) with
  `asset_token` and `secret_key` scrubbed from payloads.

**Tests (per §6):** fill success; `fill: false` + `placement: null` returns normally
(never raises); all five error codes → exception classes; 429 exposes `Retry-After`;
duplicate beacon (`duplicate: true`) is not an error; `BEACON_TOO_LATE` →
`ValidationError`; timestamps freshly generated; headers/auth correct.

## Phase 5 — Rails engine: routes, controller, helpers

Blocking path **done** (branch `phase-5-engine`); async delivery mode moved to
Phase 6 with its browser half (Daniele's call). Dev toolchain moved to Ruby
3.4.10 + Rails 8.1 here — decision #007.

- [x] `Wavebird::Facade` (fail-silent, decision #003) + `Wavebird.client`
  returning it — wraps the raising `Client`, catches `Wavebird::Error`, reports
  via `on_error`/logger, returns a no-fill/`nil`.
- [x] `Wavebird::Engine < ::Rails::Engine` (isolated namespace) +
  `config/routes.rb` mounting `POST /wavebird/sponsor_slot`.
- [x] `Wavebird::SponsorSlotsController`: calls the facade server-side,
  returns only browser-safe JSON (frame_url, script_url, dimensions, fill flag —
  **never** secret_key; asset_token only insofar as the hosted renderer needs it via
  `frame_url`); no-fill → `{ fill: false }` with 200; API errors → `{ fill: false }`
  too (host chat flow must be unaffected, §4).
- [x] `Wavebird::SlotHelper`: `wavebird_render_script_tag` (emits `/v1/render.js`
  script tag once per page), `wavebird_slot(session_id:, endpoint:, **opts)` →
  hidden **plain `<section>` + Stimulus hook** (decision #006 — *not* a Turbo
  Frame: the hosted renderer owns the element via `replaceChildren`/`hidden`, so
  Stimulus decorates it; async mode reveals it via Turbo **Streams**), matching
  the integration brief's plain-HTML example semantically.
- [ ] **Async delivery mode (Hotwire-native, opt-in `mode: :async`)** — moved to
  Phase 6 (needs the Stimulus/Turbo-Stream browser half to be testable):
  controller calls `#create_job` (non-blocking, zero added chat latency) →
  `Wavebird::DecisionPollJob` (ActiveJob, SolidQueue-compatible) polls
  `GET /v1/decisions/{slot_id}` with `wait_ms` long-poll → on decision,
  `Turbo::StreamsChannel.broadcast_*` reveals/hides the slot `<section>`. Blocking
  `wait_ms` placements flow stays the simple default (matches wavebird's
  recommended Server API pattern); async mode is the showcase.
  (Direct WebSocket to wavebird's API — TS SDK `getDecisionViaWebSocket` —
  stays out of v1; parity table documents the rationale.)
- [x] Session id helper/concern: generate + store anonymous `session[:wavebird_session_id]`.

**Tests (done):** request specs against a minimal in-memory Rails app via
rack-test (no `spec/dummy`/`rspec-rails` yet — those arrive in Phase 8) —
response JSON never contains secret_key (explicit assertion, acceptance §5);
no-fill and error paths return 200 hide-slot payloads; helper output markup
(script tag emitted once, section attributes correct). 261 examples, 100% line
+ branch, RuboCop clean.

## Phase 6 — Stimulus controller (hosted renderer glue)

Split into **6a (this phase — Stimulus glue + install docs)** and **6b (next —
async delivery mode)**, Daniele's call: the blocking default is already working
end-to-end (Phase 5), so 6a lands the browser glue as a clean, reviewable unit
and 6b tackles the heavier ActiveJob/Turbo-Stream path on its own commit
boundary. Neither half gets real (Capybara) tests until Phase 8.

### Phase 6a — Stimulus glue + install docs (this phase)

- [ ] `app/javascript/controllers/wavebird_controller.js`: loads `/v1/render.js`
  once (idempotent), degrades silently if it fails to load. render.js itself owns
  the turn: it POSTs to the slot's `data-wavebird-endpoint`, reveals the
  `<section>` on fill (mounts the iframe via `replaceChildren`/`hidden`), keeps it
  hidden on no-fill — the controller does **not** POST, parse, or toggle the
  element. Two host entry points into `window.wavebird.withTurn({target, endpoint,
  body})`, decision #008:
  - **Path C (faithful upstream global):** the host calls
    `window.wavebird.withTurn('#wavebird-slot', work)` directly, exactly per the
    integration brief — works once render.js is loaded, no Stimulus coupling.
  - **Path A (Stimulus-idiomatic bridge):** the controller listens for a
    `wavebird:turn` CustomEvent and wraps `detail.work` in `withTurn`, passing the
    stable `session_id` (from the helper's Stimulus value) as the explicit `body`
    (render.js's default body is only a random uuid). Falls back to running
    `detail.work()` unwrapped if `window.wavebird` is absent, so the chat turn is
    never blocked.
- [ ] Verify lifecycle semantics against the **actual hosted render.js** (fetched
  live 2026-07-18; exposes `withTurn`, `startTurn`, `clearPlacement`) — behavior
  parity, not code translation. Keep the snapshot in `docs/upstream/` for diffing.
- [ ] `app/javascript/wavebird/index.js`: `registerWavebirdControllers(application)`
  registering the controller under the `wavebird` identifier; ship the JS in the
  gemspec `files` glob (`app/**/*`).
- [ ] Install docs (`INSTALL.md`) for importmap AND jsbundling setups.

**Tests:** covered by Phase 8 system tests; unit-test any pure JS helpers if extracted.

### Phase 6b — Async delivery mode — **done**

- [x] Fail-silent facade methods `create_job` (→ `nil` on error) / `await_decision`
  (→ synthetic no-fill `Decision` on error, incl. `DecisionTimeoutError`), wrapping
  the raising client the same way `create_placement` is (decision #003). The client
  already provided both (`await_decision` is the upstream-faithful polling ladder,
  decision #001).
- [x] Async-mode wiring (opt-in `mode: "async"`): controller `#create` branches to
  `#create_job` (non-blocking, zero added chat latency) → enqueues
  `Wavebird::DecisionPollJob` (ActiveJob) → `facade.await_decision(slot_id)` → on
  decision, `Turbo::StreamsChannel.broadcast_replace_to` the slot's stream.
- [x] Turbo Stream subscription per slot (`wavebird_slot(async: true)` →
  `turbo_stream_from`, guarded on turbo-rails presence) + `_slot_broadcast` partial
  → the `wavebird` Stimulus controller's `signalTargetConnected` hands the payload
  to `window.wavebird.renderPlacement` (fill) / `clearPlacement` (no-fill) — the
  hosted renderer's own out-of-band entry point, so the iframe + viewability
  beacons match the blocking path (single source of truth; no Ruby iframe/beacon
  reimplementation).
- [x] **Security boundary (decision #009):** the decision poll returns the raw
  `asset_token` (no `frame_url`, unlike the placements endpoint). The server
  reconstructs `frame_url = {api_base_url}/v1/render/{token}` itself (render.js's
  own `renderFrom` formula, `CGI.escapeURIComponent` per the client's `#encode`) and
  broadcasts only that — the `asset_token` never crosses to the browser. Shared
  browser-safe projection extracted to `Wavebird::SlotPayload` (used by both the
  blocking controller and the async job); asserted by tests on both paths.
- [x] **Graceful fallback (decision #010):** async leans on ActiveJob (poll job) +
  Turbo/ActionCable (broadcast), all *optional* — the gem's runtime deps stay
  faraday + railties. `DecisionPollJob` lives off the Zeitwerk path under `lib/`,
  guarded by `return unless defined?(ActiveJob::Base)` and lazy-`require`d only on
  the async path; when Turbo/ActiveJob is absent the controller logs a one-line
  warning and degrades to the blocking default. `config.async_queue_name` (default
  `:default`) sets the job queue.

**Tests (done):** facade async methods; `SlotPayload` (token-boundary assertions
on both shapes); controller async branch + both fallbacks + the unavailable warning;
job broadcast (reveal/hide, token never in payload, guarded no-op, queue name);
helper `async:` subscription. 292 examples, 100% line + branch, RuboCop clean.
Browser lifecycle (the `signalTargetConnected` → `renderPlacement` path) is covered
by Phase 8 Capybara.

## Phase 7 — Railtie security checks — **done**

- [x] Railtie boot check (§4), two guards in `Wavebird::BootCheck`, both raising
  `ConfigurationError` loudly (decision #011):
  - **Require-context guard** (`assert_server_side_require!`, run from
    `lib/wavebird.rb` at require time): rejects a `require "wavebird"` whose first
    non-gem, non-Ruby-internal caller frame sits under a host's `app/assets` or
    `app/javascript` — the literal case §4 names. Message names the offending file
    and says where to require it instead.
  - **Asset-path scan** (`assert_assets_paths_safe!`, run from the
    `wavebird.boot_check` initializer in `Wavebird::Railtie`): rejects asset load
    paths that would publish the gem's server-side Ruby (the gem root, its `lib/`,
    or any ancestor containing it). The gem's own `app/javascript` is explicitly
    allowed — that is the documented importmap setup in INSTALL.md.
- [x] Verify no gem code path writes `secret_key` or `asset_token` to logs:
  `spec/wavebird/leak_audit_spec.rb` greps every `lib/**/*.rb` + `app/**/*.rb` for
  string interpolation of a sensitive value, with a three-entry allowlist (the
  `Bearer` header; `slot_payload`'s server-side `frame_url`; `configuration`'s
  redacting `#inspect`) each carrying its rationale. Complements the existing
  runtime leak specs (instrumentation payload, value-object/config `#inspect`,
  browser JSON, async broadcast).
- Already satisfied before this phase, re-confirmed here: blank-key raise at first
  client use (`require_secret_key` + `client_request_spec.rb`), `secret_key` out of
  `#inspect`, `asset_token` scrubbed from instrumentation and value-object output.

**Tests (done):** `boot_check_spec.rb` unit-tests both guards with injected caller
frames and asset paths (raising and passing paths, gem-own frames, Ruby internals,
`Pathname`/nil inputs, both `run(app)` branches); `railtie_spec.rb` asserts the
initializer is registered and delegates to `BootCheck.run`. 319 examples, 100%
line + branch, RuboCop clean.

**Note:** the raising path is unit-tested rather than boot-tested — the spec
harness boots one in-memory `Rails::Application` per process and cannot boot a
second (`Rails.app_class` takeover). The non-raising path is exercised for real by
that harness booting with the gem loaded. A true subprocess boot-raise test can
come with Phase 8's `spec/dummy`.

## Phase 8 — System tests (dummy app + Capybara) — **done**

- [x] Dummy Rails app under `spec/dummy/` — a real host app (routes, session
  store, Turbo Streams over ActionCable) with a chat page using the helpers and a
  registered `wavebird` Stimulus controller. **No JS build step:** an importmap
  serves ES modules straight from where they live (the gem's own `app/javascript`
  and the stimulus/turbo gems, via `JsServer`), so nothing is vendored, copied or
  symlinked and the specs load the exact files the gem ships. `rspec-rails` +
  Capybara + headless Chrome enter the suite here.
- [x] **Phase 6a paths** — both host entry points from decision #008, each across
  fill (slot revealed, frame mounted), no-fill (stays hidden, chat proceeds),
  wavebird API down, and render.js never loading (turn runs unwrapped); plus
  `session_id` propagation and secret-key exclusion. 12 examples.
- [x] **Phase 6b path** — async mode end to end over a *real* cable: mocked
  `/v1/jobs` + `/v1/decisions/{slot_id}` → endpoint answers `{pending: true}` →
  `DecisionPollJob` → genuine `Turbo::StreamsChannel` broadcast → Stimulus
  `signalTargetConnected` → `renderPlacement`. Fill reveals, no-fill stays hidden,
  a failing poll leaves the chat flow untouched, and the token boundary holds.
  5 examples.
- [x] `spec/wavebird/render_js_contract_spec.rb` keeps the local render.js
  stand-in honest against the dated upstream snapshot, so refreshing the snapshot
  fails loudly instead of silently invalidating every system test.
- [x] SimpleCov: 100% line + branch on `lib/wavebird/*` (per §6), enforced by the
  unit + request suite. The system specs run as their own process with the gate
  off — they drive the browser, not `lib/` — so the two coverage runs are written
  to separate directories.
- [x] CI: a dedicated `system` job (Ruby 3.4 + Chrome/chromedriver) running
  `rake spec:system`, split from the unit matrix because it needs a browser.

**Two bugs this phase caught** (neither visible to unit tests):
1. **Async mode was unreachable from the browser.** The helper rendered the Turbo
   Stream subscription, but nothing told the endpoint to use async — the Stimulus
   controller never sent `mode`/`stream_name`, so every async slot silently fell
   back to blocking. Fixed: the helper emits the values, the controller forwards
   them (with the position hint) in the request body.
2. **The broadcast never reached the DOM.** `DecisionPollJob` used
   `broadcast_replace_to` against a target named after the *stream*
   (`wavebird_slot_below`), which no element on the page had — and a Turbo Stream
   `replace` against a missing target is a silent no-op. Fixed: `broadcast_append_to`
   into the slot `<section>` itself (`SlotPayload.slot_dom_id`, now the single
   source of that id for both helper and job), and the Stimulus handler removes
   the signal node once consumed so repeated broadcasts cannot stack.

**Test-layout constraint:** only one Rails application can exist per process, so
the system specs run as their own process (`rake spec:system`, excluded from bare
`rspec` via `.rspec`) while the rack-test app keeps serving the request specs.
`rake` runs both, then RuboCop.

**Gate:** full matrix CI green.

## Phase 9 — Documentation & examples — **done**

- [x] README: what/why, install, Rails-flavored quickstart mirroring the brief's
  Next.js example, public API reference table, §4 privacy rules stated explicitly,
  credential-class table (sk_test/sk_dry/sk_live/pk), credits + links to
  wavebird.ai/api and the upstream TS SDK (acceptance §6).
- [x] YARD on every public method; `yard stats --list-undoc` clean (100%).
  Internal helpers carry `@api private` and are excluded via `.yardopts`
  (`--hide-api private`); `rake yard_coverage` keeps it at 100% and is part of
  the default task.
- [x] `examples/chat_with_sponsored_slot/` — initializer, routes, controllers and
  view, laid out as a host-app tree so they copy-paste directly.
- [x] CHANGELOG entry for 0.1.0.

**Beyond the checklist**
- `spec/wavebird/examples_spec.rb` pins the example files to the real API
  (config options, helper names, `wavebird_slot` keywords, the engine mount), so
  a rename breaks the build instead of shipping a quickstart that raises in a
  user's app on their first try.
- Found and fixed a genuine documentation gap: the engine isolates its namespace,
  so a host must `helper Wavebird::SlotHelper` before the view helpers resolve.
  `spec/dummy` did this; neither README nor INSTALL.md said so — the copy-pasted
  quickstart would have failed at acceptance §4. Now documented in both.
- `examples/**/*` added to the gemspec's `spec.files`.

## Phase 10 — Final audits (the two verification tracks)

**A. Parity audit vs the TypeScript SDK**
- [ ] Walk the Phase 0 parity table against final code: every ported method's
  request fields, defaults, and response handling checked against
  `public_contracts.ts` and the API reference pages, field-for-field.
- [ ] Resolve the `reportGeneration()` question (port in v1, or documented as
  out-of-scope with rationale).
- [ ] Diff the README quickstart flow against the integration brief's recommended
  architecture — same endpoints, same consent defaults, same no-fill posture.
- [ ] Re-check `https://wavebird.ai/api/changelog` for contract drift since Phase 0.

**B. Industry-standard quality audit**
- [ ] `rubocop` clean; `bundle exec rake` green; coverage threshold met.
- [ ] Run `/code-review` on the full diff; fix findings.
- [ ] Run `/security-review`: key handling, log redaction, no PII pathways,
  no secret in any JSON/HTML output (acceptance §5 has an explicit test).
- [ ] Gem hygiene checklist: semver, `rubygems_mfa_required`, no test files in the
  packaged gem (`spec.files` check), `bundle exec rake build` + local
  `gem install pkg/*.gem` smoke test in a fresh `rails new` app.
- [ ] Manual sandbox smoke test with an `sk_test_...` key against the §3.1 example
  (acceptance §4) — requires user-supplied sandbox credentials.

## Phase 11 — Release prep (not executed without explicit go-ahead)

- [ ] Tag v0.1.0, finalize CHANGELOG, `gem build` artifact ready.
- [ ] Pre-publish re-check of versioning/changelog pages (per prompt's closing note).

---

### Standing rules across all phases

- No-fill is success, never an exception; host app's AI path must never be blocked.
- `secret_key` and `asset_token` never appear in logs, `inspect`, JSON to browser,
  or asset-pipeline-reachable code.
- Port field names from docs/`public_contracts.ts` verbatim — no guessed renames.
- Tolerant reading (ignore unknown response fields), strict writing (send only
  documented request fields; never the response-only dry-run flags).
