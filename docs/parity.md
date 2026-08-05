# Parity table — wavebird TS SDK v0.1.5 → wavebird-rails

Source of truth: `upstream/wavebird/` clone (gitignored) + public API docs
(snapshots in `docs/upstream/`, gitignored). Verified 2026-07-18 against source,
not from the build prompt. Decisions requiring approval reference
`docs/DECISIONS.md`.

**Framing fact (verified in `src/index.ts` + API changelog):** the npm SDK
warns at import that it is now an *advanced compatibility layer*; wavebird's
launch baseline is "API-first, Script Tag second, SDK third". The gem therefore
ports the **canonical REST v1 contract and the SDK's observable behavior**, not
its legacy wrapper transport (`/public/wrapper/v1/*`).

## Client construction & configuration

| TS (`WavebirdClientOptions`) | Ruby | Decision | Notes |
|---|---|---|---|
| `baseUrl` (HTTPS enforced except localhost) | `config.api_base_url` | port | Mirror the HTTPS-except-localhost validation |
| `getApiKey` (callable, read per request) | `config.secret_key` static + optional callable support | port (adapted) | Accept a `Proc` for rotation parity |
| `decisionDelivery` (`auto\|ws\|polling\|callback`) | polling only in v1, surfaced as opt-in async mode (`mode: "async"`) — non-blocking `create_job` → `DecisionPollJob` long-poll → Turbo Stream reveal | adapt | Decision #001 (transport) + #009 (reveal keeps asset_token server-side) + #010 (ActiveJob/ActionCable optional, graceful fallback) + **#015 (the reveal stream is scoped per session, matching upstream's per-slot WebSocket, which is scoped to one caller by construction — a per-position stream would be shared by every visitor)**; `callback` mode not ported (needs public callback URL — see open Q3) |
| `publisher` default metadata | `config.default_publisher` | port | Merged into every job unless overridden |
| `options.timeout_ms` (default 2000, clamp 250..30000) | `config.timeout_ms` | port | Same default + clamp |
| `options.decision_timeout_ms` (default 30000, clamp 1000..60000) | `config.decision_timeout_ms` | port | Governs total poll budget — required by #001 |
| `options.long_poll_wait_ms` (default 1500, clamp 0..5000) | `config.long_poll_wait_ms` | port | Same |
| `options.short_poll_interval_ms` (default 250, clamp 100..5000) | `config.short_poll_interval_ms` | port | Same |
| `options.onError` (observer for swallowed errors) | `config.on_error` callable | port | Core to fail-silent design (see below) |
| `options.logLevel` / `logger` | `config.logger` (Rails logger default) | port (adapted) | Redaction rules apply (asset_token, secret) |
| `options.wrapper_version` (default `"sdk"`) → `x-csl-wrapper-version` header | `config.wrapper_version`, default `wavebird-rails/VERSION`, sent as both `x-csl-wrapper-version` and `User-Agent` | port (adapted) | **Verified 2026-08-04:** the live sandbox run rendered a real ad with this value, so the API accepts a non-`"sdk"` wrapper version — no need to mirror `"sdk"` (see `docs/parity-findings.md` F8) |

## Fail-silent posture (behavioral core — must match)

Verified in source: **public methods never throw.** `createJob` returns `null`
on failure; `getDecision` resolves to a no-fill fallback; `sendBeacon` resolves
`{accepted:false}`-shaped fallback; `reportGeneration` returns void. All
failures are routed to `onError` as structured `WavebirdSdkError`s.

→ Ruby port: **resolved (decision #003), both coexist and are built.** The
low-level `Wavebird::Client` raises distinct typed exceptions per HTTP error
code (build prompt §3.9); the high-level `Wavebird::Facade` — returned by
`Wavebird.client`, the public default — is fail-silent like upstream: it
catches `Wavebird::Error`, reports through `on_error` + logger, and returns a
no-fill outcome so the host flow is never broken. The engine's
`SponsorSlotsController` uses the facade, so a wavebird failure surfaces to the
browser as `{ fill: false }` with 200.

**Coverage and fallback values (decision #018, 2026-08-05).** The facade mirrors
*every* `Client` method, since upstream's whole surface is fail-silent, and its
fallback values match upstream's rather than being convenient Ruby nils:

| Method | Upstream fallback | Facade fallback |
|---|---|---|
| `create_job` | 429 → `{error: "rate_limit_exceeded", retry_after_ms}` + `warn`, never `onError`; other failures → `null` | `Types::RateLimited` (seconds, not ms) + `warn`, never `on_error`; other failures → `nil` |
| `decision` / `await_decision` | `fallbackDecision` = `{slot_id, status: "pending", fill: null}` | identical pending `Types::Decision` |
| `record_beacon` | `fallbackBeacon` = `{accepted: false, reason_code: "SDK_FAIL_SILENT"}` | identical `Types::BeaconResult` |
| `report_generation` | `void`, `@throws Never` | `true`/`false` |
| `record_consent`, `activate_browser`, `project_config` | no upstream equivalent | `nil` |

`ArgumentError` (an event outside a canonical enum) is deliberately *not*
swallowed at either layer: upstream rejects it at compile time, so it is a
caller bug rather than a wavebird failure.

## Client methods

| TS | Endpoint(s) | Ruby | Decision |
|---|---|---|---|
| `createJob(params)` | canonical `POST /v1/jobs` when params fit; legacy wrapper ingress otherwise | `#create_job` → canonical only | port (canonical only) |
| — | `POST /v1/placements?wait_ms=` (job+first decision in one call; recommended by docs, not in SDK) | `#create_placement` | **add** — docs-recommended primary path; not a deviation, it's the API-first route |
| `getDecision(slotId)` | WS → long-poll → short-poll ladder | `#decision(slot_id)` long-poll + short-poll, same budgets | adapt per #001 |
| `reportGeneration(jobId, event, req)` | `POST /v1/jobs/{job_id}/generation/{event}`; events `started\|finished\|failed`; body `generation_id`, `model_id`, `usage_json`, `error` | `#report_generation` | **ported** (decision #002 approved) — event validated locally against the canonical enum before the request, since it forms the URL path |
| `sendBeacon(beacon)` | canonical `POST /v1/beacons` (maps legacy `beacon_type`→canonical `event`, ms epoch→ISO8601); falls back to legacy wrapper path | `#record_beacon` canonical only, canonical field names (`event`, `occurred_at`) | port (canonical only) |
| — | `POST /v1/consent` | `#record_consent` | add (docs §3.7) |
| — | `POST /v1/browser/activate` | `#activate_browser` | add (docs §3.4, secondary) |
| — | `GET /v1/projects/{client_id}/config` | `#project_config` | add (docs §3.8) |
| `createDecisionWsTicket` + `getDecisionViaWebSocket` (private) | wrapper WS ticket + per-slot socket | not ported in v1 | #001 (approved; deferred todo) |
| `sendLegacyBeacon` (private) | `/public/wrapper/v1/beacons` | not ported | legacy transport |

**Legacy-only request fields, not exposed by this client.** Upstream's
`createV1JobRequest` treats several `JobRequest` fields as signals to *leave* the
canonical route: supplying `predicted_latency_ms`, `model_id`, `verification`,
`callback_url`, `routing.candidate_partner_ids`, `prompt.token_count_estimate`,
or any consent flag beyond `gdpr_applies` makes `canUseCanonicalRequest` false
(wavebird-client.ts:308–317) and sends the legacy wrapper ingress body instead.
The canonical `/v1/jobs` and `/v1/placements` bodies have no position for them —
confirmed by the sandbox's own generated example, which carries none — so a
canonical-only client cannot express them, and none are exposed here. Not a
divergence to fix: it is the same boundary upstream draws.

## Response normalization (behavioral parity details from source)

- Decision: `status:"pending"` + `decision:null` → pending result; `fill:false`
  → normal no-fill; `fill:true` requires `format`∈banner|clip|native,
  `asset_token`, `cs_declaration`, `constraints`; native requires `assets`
  (title+image_url minimum); non-native requires `delivery_url`. Malformed →
  fail-silent no-fill + onError. Port this validation logic.
- Beacon: HTTP 204 or empty body → `{accepted:true, reason_code:"OK"}`;
  tolerant of unknown fields. Port.
- `Retry-After`: parses both delta-seconds and HTTP-date; missing/invalid → 1s
  default. Port exactly.
- Client remembers `asset_token → slot_id` mapping to backfill beacon slot_ids.
  Port only if we keep beacon ergonomics identical (low priority — our beacons
  are an escape hatch).

## Exported helpers & types

| TS export | Ruby | Decision |
|---|---|---|
| `normalizeWavebirdPlacement` | internal normalization inside value objects; its *strict* render-completeness rule deliberately not ported (#021) — the hosted renderer's own `renderFrom` needs only `frame_url`, so enforcing more would hide fills it could paint. `SlotPayload` requires a usable `frame_url` and reports anything else as a no-fill | adapt (not public API) |
| `resolveAdTimingPlan` (deprecated upstream) | not ported | skip — deprecated in origin |
| `warnSdkDeprecation` (`deprecation.ts`) | `Wavebird::Deprecation.warn_once` — same key format, same once-per-process registry, writing to `config.logger` instead of `console.warn` | port (adapted) — #020; drives the `timing: before\|after` warning |
| `WavebirdSdkError` / `WavebirdSdkErrorCode` | `Wavebird::Error` hierarchy + API-code exceptions (pending Q1) | adapt |
| Types: `JobRequest`, `JobResponse`, `DecisionResponse`, `BeaconRequest/Response`, `ConsentFlags`, `GenerationEvent/Request`, `WavebirdPlacement`, frequency/pacing/targeting configs | Ruby `Data` value objects, field names verbatim | port |
| `public_contracts/wrapper.ts` runtime guards (`isCslWrapper*V1`) | schema checks inside deserializers | adapt |
| `public_contracts/ssp.ts` | not ported | skip — SSP-side contract, not publisher-side |

## Subpath exports (browser/UI surface)

| npm subpath | Ruby | Decision |
|---|---|---|
| `./react` (`WavebirdAd`), `./mount` | plain hidden `<section>` + Stimulus hook + hosted `render.js` (`withTurn`/`startTurn`/`clearPlacement`, snapshot in docs/upstream/) — **not** a Turbo Frame (decision #006): the renderer owns the element via `replaceChildren`/`hidden`, so Stimulus decorates it and async mode reveals it via Turbo Streams. The `wavebird` Stimulus controller offers two host entry points into `withTurn` (decision #008): the faithful upstream global (`window.wavebird.withTurn('#wavebird-slot', work)`) and a `wavebird:turn` CustomEvent bridge that injects the stable `session_id`. Async mode reveals the slot out-of-band by handing the broadcast payload to the renderer's own `renderPlacement`/`clearPlacement` (decision #009) — same iframe + beacon lifecycle as the sync path. Note the SDK's own `mountWavebirdAd`/`WavebirdAd` DOM builders are **deprecated** upstream in favour of this hosted `render.js` path. | adapt — per build prompt §2 and wavebird's own API-first guidance |
| `./browser` (browser client) | not ported | skip — Script Tag covers browsers |
| `./consent`, `./consent/react` (dialog, TCF strings, consent store) | `#record_consent` API only; host app CMP supplies UI | adapt (v1) — TCF string support = later todo |

## Canonical enums (verified)

- beacon `event`: `rendered|visible|clicked|completed|play_started|play_completed|heartbeat`
- generation event: `started|finished|failed`
- `job_type`: `chat|code|image|voice|agent`
- position: `above|below|sidebar|between`; formats: `banner|clip|native`
- consent decision: `personalized|basic|custom`; source: `publisher_custom|server_sync|wavebird_dialog` (+ input aliases `publisher`, `custom_dialog`)

## Phase 10 audit — parity table re-walked against final code (2026-08-02)

Every row above re-checked field-for-field against the shipped gem and the
upstream source in `upstream/wavebird/src/`. **Confirmed at parity:**

- Config defaults and clamps: `timeout_ms` 2000/250–30000, `decision_timeout_ms`
  30000/1000–60000, `long_poll_wait_ms` 1500/0–5000, `short_poll_interval_ms`
  250/100–5000; `clampInt`'s floor-then-clamp semantics ported exactly.
- `parseRetryAfterMs`: non-negative delta-seconds → HTTP-date → 1 s default, with
  the same fall-through order (a negative or non-finite value drops to the date
  branch and then to the default). Ported in seconds rather than ms.
- Base-URL normalization: HTTPS enforced except for the same `LOCALHOST_HOSTNAMES`
  set, trailing slashes stripped.
- Canonical `/v1/jobs` request body: `client_id`, `session_id`, `job_type`,
  `locale`, `slots_requested` (default 1), `prompt`, `slot_hint`, `overrides` —
  field-for-field, including `overrides.publisher` built as
  `{**default_publisher, **publisher}`.
- Beacon: 204/empty body → `{accepted: true, reason_code: "OK"}`; canonical
  `event`/`occurred_at` field names; tolerant of unknown response fields.
- Decision normalization and the polling ladder: see `decision_normalizer.rb`
  and `Client#await_decision` (2 long polls, ×1.5 backoff capped at 2 s + jitter,
  `min(120, decision_timeout_ms / short_poll_interval_ms)` attempts).
- Canonical enums, all five, unchanged.

**Deliberate divergences, now recorded explicitly:**

| Area | Upstream | Gem | Why |
|---|---|---|---|
| `prompt.text` | canonical job request accepts `prompt.text` (from `params.prompt` or `context.prompt_text`) | only `topic:` is exposed — on both `create_placement` and `create_job` (#019) — and there is no parameter that accepts user text | Build prompt §4: "the client's public API should not even have a parameter that invites this by accident." A narrowing, and intentional. |
| `overrides` sub-keys | ~12 individually typed fields (`allowed_formats`, `bidfloor`, `timing`, `frequency_cap`, `targeting`, `pacing`, `blocked_*`, …) | one free-form `overrides:` Hash merged over `config.default_overrides` | Every upstream key remains expressible; typing them in Ruby would freeze a contract that upstream still evolves. |
| non-finite numeric config | `clampInt` silently falls back to the default | raises `ConfigurationError` | `Float::INFINITY` for a timeout is a caller bug, not a default. Consistent with the existing "non-numeric raises" rule. |
| `asset_token → slot_id` memo | client remembers the mapping to backfill beacon `slot_id` | not ported | Beacons are an escape hatch here (the hosted renderer sends its own); `slot_id` is a required keyword instead. Was already flagged low-priority in Phase 0. |

**Gaps found and closed (decisions #013, #014):**

- **Consent defaults.** The integration brief's reference backend hard-codes
  `semantic_targeting: false, prompt_shared: false, consent_source: "wavebird_consent"`
  on every request; the gem sends nothing unless the caller does. Checked against
  the SDK rather than the brief: the SDK injects no defaults either, and
  `consent_source: "wavebird_consent"` appears only in its deprecated DOM
  components after a real dialog decision. **Resolved as "match the SDK"** — the
  gem is already correct, and defaulting that source would misstate provenance
  for a host using its own CMP. Documented in the README instead.
- **Async dropped consent entirely.** `create_job` had no `consent:` parameter
  and the controller stripped it, so a GDPR flag sent in blocking mode vanished
  in async mode. Now ported from upstream's `createV1JobRequest`: `gdpr_applies`
  folds into `overrides.gdpr_applies`, and any flag the canonical route cannot
  carry is named in a warning rather than dropped in silence.

## Resolved questions (see docs/DECISIONS.md)

1. Error posture → **#003 approved: layered** — `Wavebird::Client` raises typed
   errors; Rails-facing facade is fail-silent like upstream.
2. `reportGeneration` → **#002 approved: port in v1**.
3. `decisionDelivery: "callback"` → **#004 approved: later todo**; keep the
   client design open for it.
