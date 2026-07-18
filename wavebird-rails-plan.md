# wavebird-rails — Incremental Build Plan

Companion to [wavebird-rails-build-prompt.md](wavebird-rails-build-prompt.md).
Each phase ends in a green test suite and a working (if partial) gem — no phase
depends on a later one. Verification against the upstream TypeScript SDK and
industry-standard quality gates are built into every phase, plus a dedicated
audit phase at the end.

---

## Phase 0 — Pin the upstream contract (verification baseline)

- [ ] Fetch and snapshot the canonical sources into `docs/upstream/` (date-stamped):
  - `https://wavebird.ai/wavebird-api-llm-integration.md` (integration brief)
  - `https://wavebird.ai/api/reference/types`, `/errors`, `/rate-limits`
  - `https://github.com/wavebird-ai/wavebird` → `src/index.ts`, `src/public_contracts.ts`
- [ ] Build a **parity table** (`docs/parity.md`): every TS SDK export ↔ planned Ruby
  equivalent ↔ decision (port / adapt / intentionally skip + why). Known rows:
  | TS SDK | Ruby | Decision |
  |---|---|---|
  | `WavebirdClient` | `Wavebird::Client` | port |
  | `createJob()` | `#create_job` | port |
  | `getDecision()` | `#decision(slot_id)` | port |
  | `sendBeacon()` | `#record_beacon` | port (documented as advanced/optional) |
  | `reportGeneration()` | **TBD** — present in TS SDK, absent from build prompt; check docs, decide port/skip | investigate |
  | `getDecisionViaWebSocket()` (WS to wavebird API) | ActiveJob poll + Turbo Stream broadcast instead | adapt — Rails-native async delivery; direct WS to wavebird deferred to v2 |
  | `public_contracts.ts` types | `Wavebird` value objects | port field-for-field |
  | `WavebirdAd` React / `mountWavebirdAd` | Turbo Frame + hosted renderer | intentionally not ported |
  | `ConsentDialog` | `#record_consent` API only | intentionally not ported (v1) |
- [ ] Re-check `https://wavebird.ai/api/changelog` + `/api/reference/versioning`
  (prompt data was pulled 2026-07-18 — same day, but confirm).

**Gate:** parity table complete; every skipped TS feature has a written rationale.

## Phase 1 — Gem skeleton & tooling

- [ ] `bundle gem wavebird-rails` layout: `wavebird-rails.gemspec`, `lib/wavebird.rb`,
  `lib/wavebird/version.rb`, MIT `LICENSE`, `CHANGELOG.md` (Keep a Changelog), `.gitignore`.
- [ ] Gemspec: runtime deps `faraday` (~> 2), `rails` (>= 7.0 for Hotwire defaults);
  `required_ruby_version >= 3.1`; `homepage`/`source_code_uri` → this repo;
  `rubygems_mfa_required = "true"` in metadata.
- [ ] Dev tooling: RSpec, WebMock, SimpleCov (min coverage enforced), RuboCop
  (standard style, `.rubocop.yml` committed), `rake` default task = spec + rubocop.
- [ ] GitHub Actions CI: matrix over supported Ruby (3.1–3.3) × Rails (7.1, 7.2, 8.0)
  via `appraisal` or gemfiles; runs rspec + rubocop.

**Gate:** `bundle exec rake` green on empty skeleton; CI runs.

## Phase 2 — Configuration + error hierarchy

- [ ] `Wavebird::Configuration`: `secret_key`, `client_id`,
  `api_base_url` (default `https://api.wavebird.ai`), `default_slot_hint`,
  `default_overrides`, `timeout`/`open_timeout`, `logger`. `Wavebird.configure` block +
  `Wavebird.client` memoized accessor; raise `Wavebird::ConfigurationError` on first
  use with blank `secret_key` (not at boot — per prompt §6).
- [ ] `Wavebird::Errors` per §3.9: `Wavebird::Error` base exposing `request_id`,
  `code`, `docs_url`, `http_status`; subclasses `UnauthorizedError`, `ForbiddenError`,
  `RateLimitedError` (with `retry_after`), `ValidationError` (with field paths),
  `NotFoundError`, plus `APIError` fallback for unknown codes and
  `ConnectionError`/`TimeoutError` for transport failures.
- [ ] `secret_key` redacted from `Configuration#inspect` / logging.

**Tests:** config defaults, blank-key raise, every error class carries `request_id`.

## Phase 3 — Value objects (`types.rb`)

- [ ] `Data`/`Struct` value objects mirroring `public_contracts.ts` field names exactly:
  `Placement` (incl. nested `Render` with `strategy`, `frame_url`, `script_url`),
  `Decision` (`fill`, `format`, `asset_token`, `assets`), `PlacementResponse`
  (`slot_id`, `status`, `placement` may be nil, `decision`), `BeaconResult`,
  `ConsentState`, `ProjectConfig`.
- [ ] Tolerant deserialization: unknown response fields ignored (esp. beacons — §3.6),
  accessible via a raw-attributes reader; never raise on missing optional fields.
- [ ] Convenience: `PlacementResponse#fill?` (true only when placement present AND
  `decision.fill`), `#no_fill?` — no-fill is a first-class success state.
- [ ] `asset_token` redacted in `#inspect`/`#to_s` of every object carrying it (§4).

**Tests:** round-trip from the exact JSON fixtures in §3.1; nil placement; unknown
fields tolerated; `inspect` never leaks `asset_token`.

## Phase 4 — HTTP client, endpoint by endpoint

Build on Faraday with WebMock-stubbed tests per endpoint before moving to the next:

- [ ] Shared plumbing: `Authorization: Bearer`, JSON encode/decode, `User-Agent:
  wavebird-rails/x.y.z`, error-envelope → exception mapping, `X-Request-Id` capture,
  timeouts, never send `production_dry_run`/`billing_suppressed`/etc. (response-only
  fields, §3). No retry-on-failure by default for placements (latency-sensitive).
- [ ] 4.1 `#create_placement(session_id:, job_type: "chat", slots_requested: 1,
  slot_hint:, overrides:, consent:, wait_ms: 1500)` — keyword-args-only, so there is
  no slot for prompts/PII to sneak in (§4); merges configured defaults.
- [ ] 4.2 `#create_job(...)` — parity route, documented as advanced.
- [ ] 4.3 `#decision(slot_id)` — poll after `/v1/jobs` or placement timeout.
- [ ] 4.4 `#record_beacon(beacon_id:, slot_id:, asset_token:, event:, metadata: nil)` —
  generates `occurred_at` **at call time** internally (prevents `BEACON_TOO_LATE`);
  validates `event` against the seven allowed values; documented as escape hatch.
- [ ] 4.5 `#record_consent(session_id:, decision:, source:, purposes:)` — validate
  enums; accept alias sources (`publisher`, `custom_dialog`) but emit only canonical.
- [ ] 4.6 `#activate_browser(publishable_key:, origin:)` — secondary, marked as such.
- [ ] 4.7 `#project_config` — GET config.
- [ ] Instrumentation: `ActiveSupport::Notifications` (`wavebird.request`) with
  `asset_token` and `secret_key` scrubbed from payloads.

**Tests (per §6):** fill success; `fill: false` + `placement: null` returns normally
(never raises); all five error codes → exception classes; 429 exposes `Retry-After`;
duplicate beacon (`duplicate: true`) is not an error; `BEACON_TOO_LATE` →
`ValidationError`; timestamps freshly generated; headers/auth correct.

## Phase 5 — Rails engine: routes, controller, helpers

- [ ] `Wavebird::Engine < ::Rails::Engine` (isolated namespace) +
  `config/routes.rb` mounting `POST /wavebird/sponsor_slot`.
- [ ] `Wavebird::SponsorSlotsController`: calls `create_placement` server-side,
  returns only browser-safe JSON (frame_url, script_url, dimensions, fill flag —
  **never** secret_key; asset_token only insofar as the hosted renderer needs it via
  `frame_url`); no-fill → `{ fill: false }` with 200; API errors → `{ fill: false }`
  too (host chat flow must be unaffected, §4).
- [ ] `Wavebird::SlotHelper`: `wavebird_render_script_tag` (emits `/v1/render.js`
  script tag once per page), `wavebird_slot(session_id:, endpoint:, **opts)` →
  hidden Turbo Frame + data attributes for the Stimulus controller, matching the
  integration brief's plain-HTML example semantically.
- [ ] **Async delivery mode (Hotwire-native, opt-in `mode: :async`):**
  controller calls `#create_job` (non-blocking, zero added chat latency) →
  `Wavebird::DecisionPollJob` (ActiveJob, SolidQueue-compatible) polls
  `GET /v1/decisions/{slot_id}` with `wait_ms` long-poll → on decision,
  `Turbo::StreamsChannel.broadcast_*` fills/hides the slot frame. Blocking
  `wait_ms` placements flow stays the simple default (matches wavebird's
  recommended Server API pattern); async mode is the showcase.
  (Direct WebSocket to wavebird's API — TS SDK `getDecisionViaWebSocket` —
  stays out of v1; parity table documents the rationale.)
- [ ] Session id helper/concern: generate + store anonymous `session[:wavebird_session_id]`.

**Tests:** request specs — response JSON never contains secret_key (explicit
assertion, acceptance §5); no-fill and error paths return 200 hide-slot payloads;
helper output markup (script tag emitted once, frame attributes correct).

## Phase 6 — Stimulus controller (hosted renderer glue)

- [ ] `app/javascript/controllers/wavebird_controller.js`: loads `/v1/render.js`
  once (idempotent), wraps `window.wavebird.withTurn()` around the chat turn, POSTs
  to the engine endpoint, sets Turbo Frame `src`/reveals on fill, keeps hidden on
  no-fill; degrades silently if render.js fails to load.
- [ ] Verify lifecycle semantics against the **actual hosted render.js** (fetched
  live 2026-07-18; exposes `withTurn`, `startTurn`, `clearPlacement`) — behavior
  parity, not code translation. Keep the snapshot in `docs/upstream/` for diffing.
- [ ] Async-mode wiring: Turbo Stream subscription per slot
  (`turbo_stream_from`), broadcast partial that reveals the frame on fill /
  removes it on no-fill; graceful fallback when ActionCable isn't configured.
- [ ] Install docs for importmap AND jsbundling setups.

**Tests:** covered by Phase 8 system tests; unit-test any pure JS helpers if extracted.

## Phase 7 — Railtie security checks

- [ ] Railtie boot check (§4): raise loudly if the client is required from an
  asset-pipeline/`app/javascript`-reachable context; document what triggers it.
- [ ] Verify no gem code path writes `secret_key` or `asset_token` to logs
  (grep-based spec over instrumentation payloads + inspect output).

**Tests:** Railtie boot spec; blank-key raise at first client use (per §6).

## Phase 8 — System tests (dummy app + Capybara)

- [ ] Minimal dummy Rails app under `spec/dummy/` with a chat page using the helpers.
- [ ] Capybara + mocked `/v1/placements`: fill → Turbo Frame renders; no-fill →
  frame stays hidden and chat flow proceeds; wavebird API down → chat unaffected.
- [ ] Async mode: mocked `/v1/jobs` + `/v1/decisions/{slot_id}` → job runs →
  Turbo Stream broadcast fills the slot; no-fill broadcast removes it; job
  failure leaves chat flow untouched.
- [ ] SimpleCov: 100% on `lib/wavebird/*` (per §6), enforced in CI.

**Gate:** full matrix CI green.

## Phase 9 — Documentation & examples

- [ ] README: what/why, install, Rails-flavored quickstart mirroring the brief's
  Next.js example, public API reference table, §4 privacy rules stated explicitly,
  credential-class table (sk_test/sk_dry/sk_live/pk), credits + links to
  wavebird.ai/api and the upstream TS SDK (acceptance §6).
- [ ] YARD on every public method; `yard stats --list-undoc` clean.
- [ ] `examples/` minimal chat-with-sponsored-slot controller + view.
- [ ] CHANGELOG entry for 0.1.0.

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
