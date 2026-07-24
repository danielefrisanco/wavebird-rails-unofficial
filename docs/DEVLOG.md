# Devlog — wavebird-rails

Reverse chronological. Each entry: done / todo / problems found.

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
