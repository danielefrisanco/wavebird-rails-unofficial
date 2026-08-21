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
- [x] Re-check `https://wavebird.ai/api/changelog` — refetched 2026-08-02, no
  drift. **The versioning page needs no re-check: Daniele's decision (2026-08-11)
  is that the gem ships the same version as the upstream SDK it ports (0.1.5), so
  there is no independent versioning policy to verify.** Stop listing this as
  open work.

**Gate:** parity table complete; every skipped TS feature has a written rationale.

## Phase 1 — Gem skeleton & tooling — **done**

- [x] `bundle gem wavebird-rails` layout: `wavebird-rails.gemspec`, `lib/wavebird.rb`,
  `lib/wavebird/version.rb`, MIT `LICENSE`, `CHANGELOG.md` (Keep a Changelog), `.gitignore`.
- [x] Gemspec: runtime deps `faraday` (~> 2), `railties` (>= 7.1, < 9);
  `required_ruby_version >= 3.2`; `homepage`/`source_code_uri` → this repo;
  `rubygems_mfa_required = "true"` in metadata.
- [x] Dev tooling: RSpec, WebMock, SimpleCov (min coverage enforced), RuboCop
  (standard style, `.rubocop.yml` committed), `rake` default task = spec + rubocop.
- [x] GitHub Actions CI: matrix over supported Ruby × Rails via `gemfiles/`;
  runs rspec + rubocop. **Landed in Phase 10 (decision #014)** — 10 legs
  (Ruby 3.2/3.3/3.4 × Rails 7.1/7.2/8.0/8.1, minus 8.1 on 3.2/3.3). The earlier
  Ruby-only matrix was silently broken: nothing capped Rails, so every leg
  resolved 8.1.3, which does not parse on Ruby 3.3.

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
- [x] **Async delivery mode (Hotwire-native, opt-in `mode: :async`)** — moved to
  Phase 6 and shipped there (6b, decisions #001/#009/#010) (needs the Stimulus/Turbo-Stream browser half to be testable):
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

### Phase 6a — Stimulus glue + install docs — **done**

- [x] `app/javascript/controllers/wavebird_controller.js`: loads `/v1/render.js`
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
- [x] Verify lifecycle semantics against the **actual hosted render.js** (fetched
  live 2026-07-18; exposes `withTurn`, `startTurn`, `clearPlacement`) — behavior
  parity, not code translation. Keep the snapshot in `docs/upstream/` for diffing.
- [x] `app/javascript/wavebird/index.js`: `registerWavebirdControllers(application)`
  registering the controller under the `wavebird` identifier; ship the JS in the
  gemspec `files` glob (`app/**/*`).
- [x] Install docs (`INSTALL.md`) for importmap AND jsbundling setups.

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

**A. Parity audit vs the TypeScript SDK — done**
- [x] Walk the Phase 0 parity table against final code: every ported method's
  request fields, defaults, and response handling checked against
  `public_contracts.ts` and the API reference pages, field-for-field. Results and
  the four deliberate divergences are recorded in `docs/parity.md`.
- [x] Resolve the `reportGeneration()` question — decision #002 approved it for
  v1 and it shipped as `#report_generation`; the parity table's row still said
  "awaiting Daniele" and has been corrected.
- [x] Diff the README quickstart flow against the integration brief's recommended
  architecture. Same endpoints and same no-fill posture. **Consent defaults
  differ** — the brief's reference backend hard-codes protective flags, the SDK
  injects none, and the gem follows the SDK (decision #013).
- [x] Re-check `https://wavebird.ai/api/changelog` for contract drift since
  Phase 0 — refetched 2026-08-02, still "2026 Q2", identical to the snapshot.
  **No drift.**

**B. Industry-standard quality audit**
- [x] `rubocop` clean; `bundle exec rake` green; coverage threshold met.
- [x] CI matrix rebuilt as a real Ruby × Rails grid (decision #014); three legs
  verified locally — 3.3/7.1, 3.2/8.0, 3.4/8.1, all 350 examples green.
- [x] Gem hygiene: semver 0.1.0, `rubygems_mfa_required`, MIT, homepage +
  `source_code_uri` set, minimal runtime deps (faraday + railties), 31 files
  packaged with **no** test/spec files, `rake build` succeeds.
- [x] Fresh `rails new` smoke test — **done 2026-08-11, via `path:`.** Stock Rails
  8.1 app on Ruby 3.4.10, gem added by path, `rails g wavebird:install` run twice,
  server booted, `POST /wavebird/sponsor_slot` answered `{"fill":false}` with **no
  key configured** — the engine mounted at a route that serves, the facade
  swallowing the credential error, a clean no-fill rather than a 500. The whole
  promise, proven outside the test harness for the first time.

  It found a real bug on the first run: the generator's printed snippet omitted
  `mode`, and the contract spec meant to prevent exactly that drift did not list
  the generator among the files it checked. Fixed in `0d28b7a`.

  Also worth noting for anyone repeating it: run it under the right Ruby. Outside
  the repo, rbenv falls back to the global version — 3.1.4 here — and the gemspec
  correctly refuses (`requires Ruby version >= 3.2`). `rails new` then writes
  *its* Ruby into the app, so check `ruby -v` after `cd`, not only before.
- [x] `gem install` packaging test — **done 2026-08-11.** Distinct from the
  smoke test above, which used `path:` and so read the working tree, leaving
  `spec.files` untested. Built the artifact, installed it into an isolated
  `GEM_HOME` (nothing touched the real gem set), and confirmed
  `lib/generators/wavebird/install/templates/initializer.rb.tt` is present in the
  installed gem — the file the gemspec glob was widened for, and the one whose
  absence would crash the generator for every real user.

  Then ran the generator **from the installed gem**: route mounted, initializer
  written with its full documented body (so the packaged `.tt` is readable at its
  installed path, not merely present), `ApplicationController` wired, and the
  printed snippet carrying the `mode` line. Re-ran it and it skipped cleanly.

  31 files packaged, no spec files, `LICENSE.txt`/`README.md`/`INSTALL.md` and
  both runnable examples included. Runtime deps resolve to faraday + railties
  only.

  Repeat note: run it under the right Ruby. `rbenv` falls back to the global
  version outside the repo — 3.1.4 here — which both refuses the gem
  (`required_ruby_version >= 3.2`, correctly) and breaks a `GEM_HOME` populated
  under 3.4.10. `RBENV_VERSION=3.4.10` in front of the command.
- [ ] Run `/code-review` on the full diff; fix findings. **Daniele must trigger
  this** — it is user-invoked and billed.
- [x] Run `/security-review`: key handling, log redaction, no PII pathways,
  no secret in any JSON/HTML output (acceptance §5 has an explicit test).
  Run 2026-08-11 over `55563e0..HEAD` (35 files). Key handling, redaction and the
  token boundary came back clean; one finding, below. Note the command needs a
  `git` base to diff against and there is still no remote — it was pointed at the
  last-reviewed commit via a temporary local ref.
- [x] **`click_url` crosses to the browser with no scheme allowlist** —
  **resolved 2026-08-11 as decision #023: match upstream, record the risk.**
  (`slot_payload.rb:150`, from the security review.) `passthrough_render`
  forwards the API's `render.click_url` unchanged. The hosted renderer assigns it
  straight to `link.href` on an anchor styled `position:absolute;inset:0;z-index:2`
  — full-bleed over the creative, and in the **host page's** DOM, not inside the
  `sandbox='allow-scripts'` iframe. Its own guard is `str()`, which only checks for
  a non-empty string. A creative whose destination is `javascript:…` therefore runs
  in the host's origin on the first click of the ad.

  This is a field we used to withhold: before #021 the payload carried only
  `frame_url`, `script_url`, `width`, `height`, `label_text` and `sponsor_name`
  (`git show 55563e0:lib/wavebird/slot_payload.rb:86-96`). Widening the passthrough
  was right for the render block generally, but `click_url` is the one member of it
  that becomes *executable* in the host page.

  **What the verification found.** Upstream never validates the scheme anywhere:
  `placement.ts:63`, `:81`, `:113` and `wavebird-client.ts:562` do a
  `typeof === "string"` check and nothing else, and both renderers consume the
  result raw (`ad-renderer.ts:481-489` → `window.open(url)` /
  `window.location.assign(url)`; hosted `render.js` → `link.href=r.click_url`).
  So the gem is not weaker than a direct Script Tag install — it is identical to
  one. The remaining question, whether wavebird's *API* validates server-side,
  cannot be answered from the publisher side: we cannot submit a creative, so
  unlike #019 there is no sandbox call that settles it.

  **Decided: match upstream, record the risk (#023).** An `http`/`https` allowlist
  would make the gem stricter than the renderer it feeds — the trap #021 named —
  and a legitimate creative on an unusual scheme would silently lose its
  click-through. The risk is upstream's to hold, and diverging would assert a
  judgement about wavebird's server-side validation we have no evidence for.
  Revisit if wavebird ever documents the guarantee, or documents its absence.
- [x] **Docs only, from the same review — done 2026-08-11.** Stated in four
  places: the `SessionId` YARD docs, the README's integration table and async
  section, and INSTALL's async section. `SessionId` documented that hosts may
  pass their own id instead of `wavebird_session_id` (`session_id.rb:19-20`). The
  gem's own id is `"sess_#{SecureRandom.uuid}"`, so the async stream scope of #015
  holds — the endpoint takes `session_id` from the request and derives the
  broadcast target from it, which is only safe because that value is unguessable.
  A host substituting a sequential or user-derived id silently reopens the
  cross-session injection #015 closed. Not a vulnerability today; the docs now say
  the substitute must be unguessable and per-browser, rather than leaving it as an
  unqualified "pass that value instead".
- [x] Manual sandbox smoke test with an `sk_test_...` key against the §3.1 example
  (acceptance §4). Run 2026-08-04 as a real host app on localhost against the live
  sandbox — the first time the gem met the **real** hosted `render.js`. It found
  the worst bug of the build: the browser payload was a flat projection the
  renderer could not resolve, so no ad had ever rendered outside the test
  stand-in, silently, in either delivery mode (decision #017).
- [x] Close the gap that hid it: `render_js_contract_spec.rb` now pins the payload
  **shape**, not just the entry-point names — it asserts the snapshot source lines
  that decide whether a response paints anything, pins `frame_url` to the exact
  `placement.render` path, and (where node is available) runs the snapshot's own
  `placementFrom`/`renderFrom` against the real `SlotPayload` output, including a
  case asserting the old flat shape resolves to nothing. Verified by reverting the
  fix: 3 examples fail.

## Phase 10.5 — Install generator & onboarding (scope decision open)

**Why this exists.** Running the gem as a real host app (2026-08-04) showed the
install is long: mount the engine, write an initializer, `helper
Wavebird::SlotHelper`, `include Wavebird::SessionId`, two importmap pins **plus**
adding the gem's `app/javascript` to the asset load path, register the Stimulus
controller, then two view helpers and a turn dispatch. Eight steps, and steps
5–6 depend on the host's JS toolchain — the part the gem cannot test for them.
The vendor's own path is three steps (`<script>`, a div, `withTurn`). If the
Rails port is harder to adopt than the thing it wraps, that is a product problem,
not a docs problem. Raised by Daniele.

- [x] `rails g wavebird:install` — **done 2026-08-11.** Mounts the engine (with a
  `--mount-at` option), writes `config/initializers/wavebird.rb` from a documented
  template, and wires `helper`/`include` into `ApplicationController`. Idempotent
  and it says what it skipped; it fills in only what is missing after a partial
  manual install, and an app with no `ApplicationController` is a skip, not an
  error. 15 specs drive it against throwaway app skeletons.

  **The importmap pins and asset path are deliberately not automated** — the
  original scope assumed them, but leading the docs with the plain path removed
  the need: that install has no JS toolchain step to automate. Hosts who want
  Stimulus follow INSTALL.md, where the pins belong to their own build setup.

  Two things worth keeping. The generator's idempotency checks first read
  *relative* paths, which resolve against the process CWD, not the target app —
  so every check inspected **the gem's own** `config/routes.rb`, which mounts the
  engine, and every install silently skipped itself. Thor's file *actions* are
  destination-aware; plain `File.read` is not. And the initializer template is
  `.tt`, not `.rb`: a loadable `.rb` under `lib/` is a config file that would run
  itself if anything ever eager-loaded the directory. That needed a matching
  gemspec glob, verified by building the gem and listing its contents.
- [x] Lead the docs with the **no-Stimulus path** — **done 2026-08-07**. Path C
  needs neither importmap pins nor controller registration, so steps 5 and 6
  vanish; it already worked (decision #008) but the docs presented Stimulus
  first, so it read as mandatory. README and INSTALL now lead with it.
  The restructure turned up a substantive correction: the docs claimed path C
  could not carry a stable `session_id`. That is true only of the bare selector
  form. `readTurnOptions` in the render.js snapshot honours
  `withTurn({target, body}, work)`, so the plain path is full-fidelity, not a
  degraded one — the slot already exposes its session id and position as data
  attributes. Pinned by a contract spec so an upstream change cannot silently
  downgrade it back to a random session per turn.
- [x] **Improve the examples** — **done 2026-08-11, revised the same day.** Two
  runnable single-file apps, one per integration path, after Daniele pointed out
  the first cut was both ugly and missing the Hotwire half: `chat_plain.rb`
  (no Hotwire) and `chat_hotwire.rb` (Stimulus + async Turbo Stream). Both are
  styled after upstream's own `browser-chat.html` — the bare unstyled page read
  as broken — and both carry a status panel saying whether an empty slot is a
  no-fill or a failure, since those look identical otherwise (the #017 trap).
  Each is a complete integration in one file: engine, initializer, helper
  opt-in, slot and turn wiring, no `rails new` and no build step. It uses the
  plain-JavaScript path, matching what the docs now lead with. **Verified running**
  — `GET /` 200 with the slot section and its data attributes, `POST
  /wavebird/sponsor_slot` → `{"fill":false}` with no key (the documented
  fail-silent no-fill, and the `on_error` hook reporting the missing `client_id`),
  `POST /messages` 200, no secret or token anywhere in the page.

  `chat_with_sponsored_slot/` is kept rather than deleted, repositioned as the
  file-placement *and* Stimulus counterpart — the two things a single file cannot
  demonstrate. `examples/README.md` indexes both and says which to start with.

  Two things worth remembering from building it: `bundler/inline` was abandoned
  because bundler 2.5.3 conflicts with the default `timeout` gem, which would have
  made the example fail on a clean machine for reasons having nothing to do with
  this gem; and the Rack handler namespace moved between rack 2, rack 3 and the
  extracted `rackup` gem, so it uses `Puma::Server` directly.
- [x] Optional: a runnable demo so "see it working" is one command —
  **superseded 2026-08-11.** `examples/chat_plain.rb` already is one
  command (`bundle exec ruby examples/chat_plain.rb`) and lives in the
  repo, where a rake task wrapping a scratchpad app would not. Not adding a task
  that only re-spells a command the example already documents.

**Open:** does this land in 0.1.0 (before Phase 11) or straight after? Shipping a
gem whose install is documented-but-fiddly is defensible for a 0.1.0; shipping
one that is *hard* is not.

## Phase 11 — Release prep (not executed without explicit go-ahead)

- [ ] Tag the release, finalize CHANGELOG, `gem build` artifact ready.
  **Version tracks the upstream SDK** — Daniele's decision, 2026-08-11: the gem
  ships the version of the SDK it ports, currently **0.1.5**, not an independent
  0.1.0. `lib/wavebird/version.rb` still says 0.1.0 and needs updating as part of
  this step.
- [ ] Pre-publish re-check of the changelog page for contract drift. (The
  versioning page is moot — see above; we do not set our own policy.)

## Future — raised, not scheduled

Both raised by Daniele on 2026-08-07. Neither is a parity gap to be closed on
sight: each reverses an approved decision, so each needs its own decision entry
before any code moves.

- [ ] **Rethink the WebSocket transport.** Upstream's decision transport is a
  per-slot WebSocket (`createDecisionWsTicket` → open → one message → close),
  with polling as the *fallback*. We ship polling only, plus an ActiveJob +
  Turbo Stream async mode (#001, #015, #016). Worth revisiting because the
  upstream shape is scoped to one caller by construction — that property is what
  #015 had to rebuild by hand after the shared-channel leak. Open questions when
  we pick it up: does ActionCable earn its place next to Turbo Streams, or does
  it duplicate it; who owns the socket lifecycle in a Rails request cycle; and
  does the ticket endpoint exist on the canonical route or only the legacy
  wrapper (unverified — check before designing).
- [ ] **Consider a React surface.** Today: hidden `<section>` + Stimulus + the
  hosted `render.js` (#006, #008, #009). Upstream ships React bindings, but its
  own `mount` DOM builders are deprecated, so "port what upstream has" is not
  the brief — the question is what a React host app actually needs from a Rails
  gem. Note the seam already exists: Path C (`window.wavebird.withTurn(sel,
  work)`) is framework-agnostic and needs no Stimulus, so a React wrapper would
  likely sit on that rather than on the engine's Stimulus controller.

Examples are tracked in Phase 10.5, not here.

---

### Standing rules across all phases

- No-fill is success, never an exception; host app's AI path must never be blocked.
- `secret_key` and `asset_token` never appear in logs, `inspect`, JSON to browser,
  or asset-pipeline-reachable code.
- Port field names from docs/`public_contracts.ts` verbatim — no guessed renames.
- Tolerant reading (ignore unknown response fields), strict writing (send only
  documented request fields; never the response-only dry-run flags).
