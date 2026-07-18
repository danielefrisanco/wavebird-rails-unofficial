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
| `decisionDelivery` (`auto\|ws\|polling\|callback`) | polling only in v1 | adapt | Decision #001; `callback` mode not ported (needs public callback URL — see open Q3) |
| `publisher` default metadata | `config.default_publisher` | port | Merged into every job unless overridden |
| `options.timeout_ms` (default 2000, clamp 250..30000) | `config.timeout_ms` | port | Same default + clamp |
| `options.decision_timeout_ms` (default 30000, clamp 1000..60000) | `config.decision_timeout_ms` | port | Governs total poll budget — required by #001 |
| `options.long_poll_wait_ms` (default 1500, clamp 0..5000) | `config.long_poll_wait_ms` | port | Same |
| `options.short_poll_interval_ms` (default 250, clamp 100..5000) | `config.short_poll_interval_ms` | port | Same |
| `options.onError` (observer for swallowed errors) | `config.on_error` callable | port | Core to fail-silent design (see below) |
| `options.logLevel` / `logger` | `config.logger` (Rails logger default) | port (adapted) | Redaction rules apply (asset_token, secret) |
| `options.wrapper_version` → `x-csl-wrapper-version` header | send `wavebird-rails/VERSION` equivalent | port (adapted) | Verify server accepts arbitrary values; else mirror `"sdk"` |

## Fail-silent posture (behavioral core — must match)

Verified in source: **public methods never throw.** `createJob` returns `null`
on failure; `getDecision` resolves to a no-fill fallback; `sendBeacon` resolves
`{accepted:false}`-shaped fallback; `reportGeneration` returns void. All
failures are routed to `onError` as structured `WavebirdSdkError`s.

→ Ruby port: same posture on the *placement path* (`create_job`, `decision`
never raise in the request path; errors go to `on_error` + logger). **Open
question for Daniele (Q1):** the build prompt §3.9 instead demands distinct
raised exceptions per HTTP error code. Both can coexist (raise-y low-level
`Client`, fail-silent high-level facade), but which is the public default must
be decided — this is a real TS↔prompt conflict.

## Client methods

| TS | Endpoint(s) | Ruby | Decision |
|---|---|---|---|
| `createJob(params)` | canonical `POST /v1/jobs` when params fit; legacy wrapper ingress otherwise | `#create_job` → canonical only | port (canonical only) |
| — | `POST /v1/placements?wait_ms=` (job+first decision in one call; recommended by docs, not in SDK) | `#create_placement` | **add** — docs-recommended primary path; not a deviation, it's the API-first route |
| `getDecision(slotId)` | WS → long-poll → short-poll ladder | `#decision(slot_id)` long-poll + short-poll, same budgets | adapt per #001 |
| `reportGeneration(jobId, event, req)` | `POST /v1/jobs/{job_id}/generation/{event}`; events `started\|finished\|failed`; body `generation_id`, `model_id`, `usage_json`, `error` | `#report_generation` | **recommend port** (decision #002, awaiting Daniele): canonical v1 route, trivial, needed for `timing: "during"` server flows |
| `sendBeacon(beacon)` | canonical `POST /v1/beacons` (maps legacy `beacon_type`→canonical `event`, ms epoch→ISO8601); falls back to legacy wrapper path | `#record_beacon` canonical only, canonical field names (`event`, `occurred_at`) | port (canonical only) |
| — | `POST /v1/consent` | `#record_consent` | add (docs §3.7) |
| — | `POST /v1/browser/activate` | `#activate_browser` | add (docs §3.4, secondary) |
| — | `GET /v1/projects/{client_id}/config` | `#project_config` | add (docs §3.8) |
| `createDecisionWsTicket` + `getDecisionViaWebSocket` (private) | wrapper WS ticket + per-slot socket | not ported in v1 | #001 (approved; deferred todo) |
| `sendLegacyBeacon` (private) | `/public/wrapper/v1/beacons` | not ported | legacy transport |

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
| `normalizeWavebirdPlacement` | internal normalization inside value objects | adapt (not public API) |
| `resolveAdTimingPlan` (deprecated upstream) | not ported | skip — deprecated in origin |
| `WavebirdSdkError` / `WavebirdSdkErrorCode` | `Wavebird::Error` hierarchy + API-code exceptions (pending Q1) | adapt |
| Types: `JobRequest`, `JobResponse`, `DecisionResponse`, `BeaconRequest/Response`, `ConsentFlags`, `GenerationEvent/Request`, `WavebirdPlacement`, frequency/pacing/targeting configs | Ruby `Data` value objects, field names verbatim | port |
| `public_contracts/wrapper.ts` runtime guards (`isCslWrapper*V1`) | schema checks inside deserializers | adapt |
| `public_contracts/ssp.ts` | not ported | skip — SSP-side contract, not publisher-side |

## Subpath exports (browser/UI surface)

| npm subpath | Ruby | Decision |
|---|---|---|
| `./react` (`WavebirdAd`), `./mount` | Turbo Frame + hosted `render.js` (`withTurn`/`startTurn`/`clearPlacement`, snapshot in docs/upstream/) | adapt — per build prompt §2 and wavebird's own API-first guidance |
| `./browser` (browser client) | not ported | skip — Script Tag covers browsers |
| `./consent`, `./consent/react` (dialog, TCF strings, consent store) | `#record_consent` API only; host app CMP supplies UI | adapt (v1) — TCF string support = later todo |

## Canonical enums (verified)

- beacon `event`: `rendered|visible|clicked|completed|play_started|play_completed|heartbeat`
- generation event: `started|finished|failed`
- `job_type`: `chat|code|image|voice|agent`
- position: `above|below|sidebar|between`; formats: `banner|clip|native`
- consent decision: `personalized|basic|custom`; source: `publisher_custom|server_sync|wavebird_dialog` (+ input aliases `publisher`, `custom_dialog`)

## Open questions for Daniele

1. **Q1 — error posture conflict** (see Fail-silent section): TS SDK never
   throws; build prompt demands per-code exceptions. Proposal: low-level
   `Wavebird::Client` raises typed errors (Ruby-idiomatic, testable); the
   Rails-facing layer (controller concern/helpers, `create_placement` facade)
   is fail-silent like upstream. Needs a decision entry either way.
2. **Q2 = decision #002** — `reportGeneration`: recommend **port** (evidence in
   table above).
3. **Q3 — `decisionDelivery: "callback"` mode** (job carries `callback_url`,
   wavebird POSTs the decision to it): a Rails engine could support this
   naturally with a mounted callback route. Not in build prompt. Port later /
   never / v1?
