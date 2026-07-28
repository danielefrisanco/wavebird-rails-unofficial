# Devlog — wavebird-rails

Reverse chronological. Each entry: done / todo / problems found.

## 2026-07-28 — Phase 6b: Async delivery mode (ActiveJob poll → Turbo Stream)

**Done**
- Opt-in `mode: "async"`: controller `#create` branches to a non-blocking
  `create_job`, enqueues `Wavebird::DecisionPollJob`, and returns `{ pending: true }`
  — zero added chat latency. The job long-polls `await_decision` server-side and
  broadcasts a Turbo Stream that reveals/hides the slot.
- Facade extended fail-silently (decision #003): `create_job` → `nil` on error;
  `await_decision` → synthetic ready no-fill `Decision` on any error, including
  `DecisionTimeoutError`.
- `Wavebird::SlotPayload`: extracted the browser-safe projection so the blocking
  controller (from a `PlacementResponse`) and the async job (from a `Decision`)
  share one source of truth.
- Reveal path: `_slot_broadcast` partial → the `wavebird` Stimulus controller's
  `signalTargetConnected` hands the payload to `window.wavebird.renderPlacement`
  (fill) / `clearPlacement` (no-fill) — the hosted renderer's own out-of-band
  entry point, so iframe + viewability beacons match the blocking path.
- `wavebird_slot(async: true)` emits `turbo_stream_from` (guarded on turbo-rails).

**Decisions / research**
- #009 (security-first, Daniele): the decision poll returns the raw `asset_token`,
  not a `frame_url`. The **server** reconstructs `frame_url` from the token
  (render.js's `renderFrom` formula, `CGI.escapeURIComponent` per the client's
  `#encode`) and broadcasts only that — the token never crosses to the browser.
  Chose `renderPlacement` (the SDK's own out-of-band renderer) over Ruby-rendered
  iframes after reading the render.js snapshot: it keeps beacon parity and one
  source of truth. Researched: the SDK's own DOM components (`mountWavebirdAd`) are
  *deprecated* and build the DOM themselves; the hosted `render.js` path is the
  current, non-deprecated one — so `renderPlacement` is also "closest to the SDK".
- #010 (optional-dep graceful fallback, Daniele): ActiveJob + Turbo/ActionCable are
  optional. Runtime deps stay faraday + railties; the job lives off the Zeitwerk
  path, guarded (`return unless defined?(ActiveJob::Base)`) and lazy-required; the
  controller falls back to blocking + one warning when they're absent. `activejob`
  is a dev-only dep. Confirmed the bundle ships neither activejob nor actioncable
  by default, which is why this had to be optional.

**Verification**
- `rake` green on Ruby 3.4.10: 292 examples, 100% line + branch, RuboCop clean.
  Token-boundary assertions on both the blocking and async paths. Browser
  `signalTargetConnected → renderPlacement` lifecycle is Phase 8 Capybara.

## 2026-07-28 — Phase 6a: Stimulus controller (hosted-renderer glue) + install docs

**Done**
- `app/javascript/controllers/wavebird_controller.js`: decorates the slot
  `<section>`. Loads `/v1/render.js` once per page (idempotent — skips if
  `window.wavebird` or a matching `<script>` already present) and degrades
  silently on load failure. render.js owns the turn (POST, reveal, iframe mount),
  so the controller never fetches or toggles the element — it only bridges the
  host's chat turn into `window.wavebird.withTurn(...)`.
- Two host entry points (decision #008): **path C** — the faithful upstream
  global `window.wavebird.withTurn('#wavebird-slot', work)` keeps working
  untouched; **path A** — a `wavebird:turn` CustomEvent carrying `detail.work`,
  wrapped in `withTurn` with the stable `session_id` injected as the explicit
  request body (render.js's own default body is just a random uuid). Path A runs
  `detail.work()` unwrapped when `window.wavebird` is absent, and supports an
  optional `detail.done(error, value)` for hosts that dispatch fire-and-forget.
- `app/javascript/wavebird/index.js`: `registerWavebirdControllers(application)`
  registering the controller under the `wavebird` identifier. Both JS files ship
  via the gemspec `app/**/*` glob (verified with `gem build`).
- `INSTALL.md` (importmap + jsbundling setups, both host entry points, verify
  checklist); added to the gemspec `files` glob so it ships with the gem.

**Decisions**
- Split Phase 6 into **6a (this — Stimulus glue + docs)** and **6b (next — async
  delivery mode)**, Daniele's call. The blocking default already works end-to-end
  (Phase 5), so 6a is a clean reviewable unit and the heavier ActiveJob/Turbo-
  Stream path lands on its own boundary. Phase 8's Capybara coverage remapped to
  both halves (paths A + C, plus the async broadcast).
- #008 logged: two host entry points rather than inventing one Rails-only
  interface — the vendor's own standard is a framework-agnostic global, which we
  keep, plus the Stimulus-idiomatic CustomEvent bridge for Hotwire hosts.

**Verification**
- `rake` green on Ruby 3.4.10: 261 examples, 100% line + branch, RuboCop clean.
  The JS is inert to the Ruby suite; its lifecycle is exercised by Phase 8
  Capybara. Controller checked against the render.js snapshot: passes a
  `{target, endpoint, body}` options object, which `readTurnOptions` correctly
  detects, and reads the endpoint from `data-wavebird-endpoint` (matching
  `readEndpoint`).

## 2026-07-26 — Phase 5: Rails engine, fail-silent facade, helpers (blocking path)

**Done**
- Branch `phase-5-engine`. Fail-silent `Wavebird::Facade` (decision #003) wraps
  `Client`: `create_placement`/`record_beacon` catch `Wavebird::Error`, report
  through the same `on_error`/logger channel the polling ladder uses, and return
  a synthetic no-fill / `nil` so an ad failure never breaks the host flow.
  `Wavebird.client` is the facade — the fail-silent layer is the public default.
- `Wavebird::Engine < ::Rails::Engine` (isolated namespace) + `config/routes.rb`
  → `POST /wavebird/sponsor_slot`. Loaded from `wavebird-rails.rb` only when
  Rails is present, so `require "wavebird"` stays a client-only path.
- `Wavebird::SponsorSlotsController`: calls the facade server-side, returns
  browser-safe JSON only. **Secret key never in the response** (asserted in a
  spec); no-fill and any swallowed error both → `{ fill: false }` with 200. The
  user's raw prompt is deliberately not accepted as a param (privacy §4).
- `Wavebird::SlotHelper` (`wavebird_render_script_tag` emitted once/page,
  `wavebird_slot` → hidden `<section>` + Stimulus hook — decision #006) and
  `Wavebird::SessionId` concern (anonymous `sess_` id in the session).
- Test harness: a minimal in-memory `Rails::Application` mounts the engine and
  is driven with `rack-test` (new dev dep) — real request specs without a
  `spec/dummy` app or `rspec-rails` (those arrive with Phase 8's Capybara).
- 261 examples, 100% line + branch, RuboCop clean.

**Todo**
- Phase 6: Stimulus controller + async mode (`create_job` → `DecisionPollJob` →
  Turbo **Stream** broadcast into the slot `<section>`). Blocking path is done;
  async was scoped to Phase 6 with its browser half (Daniele's call).
- README: `data_redactor` optional integration + keep `prompt` caller-
  transformable (parked in TODO.md).

**Problems found**
- **Ruby/Rails version reality (decision #007):** Rails 8.1.3's `actionview`
  uses Ruby 3.4+ syntax and won't parse on Ruby 3.3.0; earlier phases passed
  only because they never loaded actionview. Resolved by moving to Ruby 3.4.10.
- Isolated engine developed in-place: the test app shared the gem's
  `config/routes.rb`, drawing the engine's route twice (`Invalid route name`).
  Fixed by giving the test app its own throwaway `config.root` (a tmpdir).
- Rails 8.1 `HostAuthorization` blocked rack-test's `example.org` host (403) →
  `config.hosts.clear` in the test app.
- WebMock does not match a query-bearing request (`?wait_ms=1500`) against a
  bare stub URL; controller specs stub via `.with(query: hash_including({}))`,
  same idiom the decision specs already use.

## 2026-07-24 (later) — Phase 4: close-out (validation, UA, instrumentation)

**Done**
- Closed the three build-prompt gaps the audit found (none are upstream ports):
  - `#record_beacon` / `#record_consent` validate their canonical enums
    locally, raising `ArgumentError` before the request — decision #005.
    Upstream doesn't validate (unknown beacon types fall back to the legacy
    wrapper endpoint we don't mirror; it has no consent method at all).
  - `User-Agent: wavebird-rails/x.y.z` header. Upstream sends no UA.
  - `ActiveSupport::Notifications` `wavebird.request` event per request,
    payload `{method, path, status}` (+ `error` class on failure). Guarded via
    `notifications_available?` so the client still works without ActiveSupport;
    payload deliberately excludes body/query/headers/secret_key/asset_token.
- Test env now requires `active_support` + `.../notifications` (present in any
  real install via railties) so the instrumentation path is exercised; a
  stubbed `notifications_available?` proves the bare-Ruby no-op path.
- 224 examples, 100% line + branch, RuboCop clean.

**Problems found**
- `require "active_support/notifications"` alone raises
  `uninitialized constant ActiveSupport::IsolatedExecutionState` at
  instrument time — needs `require "active_support"` first.
- Phase 7's leak check (grep instrumentation payloads for secrets) is already
  satisfied for the client: a spec asserts the payload carries neither
  `sk_test` nor `asset_token`.

## 2026-07-24 — Phase 4: HTTP client (specs completed)

**Done**
- Branch `phase-4-client`: `Wavebird::Client` covers all nine canonical v1
  endpoints (`create_placement`, `create_job`, `decision`, `await_decision`,
  `record_beacon`, `report_generation`, `record_consent`, `activate_browser`,
  `project_config`) plus `DecisionNormalizer`.
- Added the missing endpoint specs: decisions + polling ladder
  (`client_decisions_spec`), beacons/consent/browser activation
  (`client_beacons_spec`), and `#project_config`'s own guards.
- 204 examples, 100% line + branch coverage, RuboCop clean.
- `.rubocop.yml` widened with documented reasons: Metrics exclusions for
  `client.rb`/`decision_normalizer.rb` (they port upstream validation branch
  for branch), `CountKeywordArgs: false` (endpoint methods take the request
  contract as kwargs), `RSpec/DescribeMethod` off (client specs are grouped by
  endpoint, not method).

**Todo**
- Phase 5 next: the fail-silent Rails-facing facade (decision #003) + engine.
- README: document `data_redactor` as an optional integration — see TODO.md
  (docs only, deliberately not a gemspec dependency).

**Problems found**
- **Real bug caught by a spec:** connect-phase timeouts arrive as
  `Faraday::ConnectionFailed` wrapping `Net::OpenTimeout`, not
  `Faraday::TimeoutError`, so every connect timeout was misclassified as
  `ConnectionError`. Since `TimeoutError` and `ConnectionError` are different
  branches of the public hierarchy (and the Phase 5 facade will likely treat
  timeouts as retryable), this mattered. Fixed by inspecting the wrapped cause
  (`timeout_cause?`); upstream treats any timed-out request as a timeout.
- Backoff is monotonic only until `BACKOFF_CAP_MS`; past the cap jitter makes
  successive waits wobble around it. First assertion asserted global
  monotonicity and was wrong — the client was correct.

## 2026-07-18 (night) — Phase 3: value objects

**Done**
- Branch `phase-3-types`: `Wavebird::Types` ported field-for-field from
  `public_contracts/wrapper.ts` + `common.ts` + the Server API placement shape
  (`WavebirdPlacement`): PlacementResponse, Placement, Render, Decision
  (3 variants), Creative, NativeAssets, AcceptedJob, BeaconResult,
  ConsentState, ProjectConfig. Tolerant reads, raw preserved, string/symbol
  keys accepted. 88 examples, 100% line+branch, RuboCop clean.

**Todo**
- Phase 4 next: HTTP client endpoint-by-endpoint (branch `phase-4-client`).

**Problems found**
- Redaction specs caught a real leak: `render.frame_url` embeds the asset
  token (`/v1/render/{asset_token}`), so masking only `asset_token` wasn't
  enough — `frame_url` is now masked too (SafeInspect#extra_sensitive_members).
- Ruby gotcha: constants assigned inside a `Data.define` block are lexically
  scoped to the enclosing module, not the new class — used a class method
  instead.

## 2026-07-18 (evening) — Phase 2: configuration + errors

**Done**
- Daniele confirmed: gemspec homepage OK for now, Ruby >= 3.2 floor OK,
  workflow is local-only (no GitHub remote yet; CI file kept for later).
- Branch `phase-2-config-errors`: `Wavebird::Configuration` (upstream-parity
  defaults/clamps from `clampInt` call sites, HTTPS-except-localhost URL
  normalization from `normalizeBaseUrl`, callable secret key per `getApiKey`,
  redacting `inspect`), `Wavebird::Error` hierarchy per §3.9 + decision #003,
  `Wavebird.configure/configuration/reset_configuration!`.
- 65 examples green, 100% line+branch coverage, RuboCop clean.

**Todo**
- Phase 3 next: value objects (types) from `public_contracts/wrapper.ts`.

**Problems found**
- Deviation noted in code docs: non-numeric config values raise
  `ConfigurationError` (TS compiler rejects these at build time — raising is
  the Ruby analog; clamping/nil-default behavior matches upstream exactly).

## 2026-07-18 (later still) — Phase 1: skeleton

**Done**
- Decisions #002/#003/#004 approved by Daniele (see DECISIONS.md); recorded.
- Branch `phase-1-skeleton`: gemspec (faraday ~> 2, railties >= 7.1 < 9,
  Ruby >= 3.2 floor, rubygems_mfa_required), lib entry points, MIT license
  with upstream attribution, Keep-a-Changelog, pre-release README.
- Tooling: RSpec + SimpleCov (100% line+branch enforced) + WebMock
  (net disabled) + dotenv (`.env.test`, example committed), RuboCop
  (+rake/+rspec plugins) clean, `rake` default = spec + rubocop — all green.
- CI: GitHub Actions, Ruby 3.2/3.3/3.4 matrix + lint job.
- Local dev pinned to Ruby 3.3.0 (`.ruby-version`, rbenv); `gem build`
  verified — packaged files exclude specs/docs.

**Todo**
- Confirm gemspec `homepage` URL with Daniele (assumed
  `github.com/danielefrisanco/wavebird-rails`; no remote configured yet).
- Rails-version matrix (7.1/7.2/8.0 gemfiles) when engine code lands (Phase 5).
- Phase 2 next: Configuration + error hierarchy (branch `phase-2-config-errors`).

**Problems found**
- Ruby floor: system ruby was EOL 3.1.4; chose >= 3.2 floor (Rails 8's floor)
  and 3.3.0 for dev. Flag if wider compatibility is wanted.
- `Naming/FileName` vs hyphenated entry file: excluded in .rubocop.yml
  (same situation as turbo-rails).

## 2026-07-18 (later) — Phase 0: parity

**Done**
- Initial commit on `main`; phase work on branch `phase-0-parity`.
- Snapshotted docs (md-converted) + `render.js` into `docs/upstream/` (gitignored per Daniele — local reference only, like `upstream/`).
- Changelog/versioning re-checked: latest entry "2026 Q2", no drift vs build prompt.
- Full parity table written: `docs/parity.md` (verified against source, incl. client option defaults/clamps, fail-silent posture, normalization rules, canonical enums).
- Decision #002 investigated (recommend port); new open decisions #003 (error posture), #004 (callback delivery mode).

**Todo**
- Daniele's calls on #002/#003/#004, then Phase 1 (gem skeleton) on a new branch.
- Later: TCF consent-string support (upstream `./consent` subpath); Rails↔wavebird WS transport (#001).

**Problems found**
- npm SDK self-deprecates at import ("advanced compatibility layer"; baseline is API-first) — confirms our REST-canonical architecture; gem must NOT mirror legacy `/public/wrapper/v1/*` transport.
- TS↔build-prompt conflict on error handling (→ #003); build prompt's beacon `completed` event exists in canonical enum but upstream SDK maps a richer legacy set — canonical names adopted.
- Docs pages are JS-chromed HTML; wrote a local extractor (scratchpad `html2md.py`) for diffable md snapshots.

## 2026-07-18

**Done**
- Verified upstream is live; cloned TS SDK v0.1.5 to `upstream/` (gitignored).
- Wrote build plan (`wavebird-rails-plan.md`) and way of work (`WAY_OF_WORK.md`).
- Fetched live hosted `render.js` (12KB; exposes `withTurn`, `startTurn`,
  `clearPlacement`) — closes the renderer-contract gap.
- Started decision log (DECISIONS.md #001, #002).

**Todo**
- Phase 0: snapshot docs into `docs/upstream/`, build parity table from
  `src/public_contracts/` + `wavebird-client.ts`.
- Resolve decision #002 (`reportGeneration`).
- Later (post-v1): Rails↔wavebird WS decision transport, per decision #001.
- Sandbox credentials: Daniele will request from wavebird later — live smoke
  test parked until then; all development against mocked HTTP.

**Problems found**
- Upstream SDK is richer than the build prompt: WebSocket decision delivery,
  `reportGeneration()`, deprecation layer, TCF consent strings — parity table
  must classify each explicitly rather than trusting the prompt's file list.
