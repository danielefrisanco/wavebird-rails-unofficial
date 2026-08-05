# Parity findings — re-review of 2026-08-05

An independent re-walk of the shipped gem against the upstream TypeScript SDK
(`upstream/wavebird/src/`, v0.1.5), done after the Phase 10 audit and the #017
payload fix. It answers one question: **does our API behave the same way as the
original?**

Sources: upstream source (not the build prompt), `docs/upstream/` snapshots,
`docs/parity.md`, `docs/DECISIONS.md`. State of the tree at review time:
branch `phase-10-audits`, `12fc1ce`, suite green (379 examples, 100 % line +
branch).

Nothing here has been changed in code. Section 3 items are **open** and need
Daniele's decision (WAY_OF_WORK rules 1 and 4); whatever is decided moves into
`docs/DECISIONS.md` and the summary rows into `docs/parity.md`.

---

## 1. Confirmed at parity

Re-verified field-for-field this round; all already claimed in `docs/parity.md`
and all still true.

| Area | Upstream | Gem |
|---|---|---|
| Numeric config | `clampInt`: `timeout_ms` 2000/250–30 000, `decision_timeout_ms` 30 000/1000–60 000, `long_poll_wait_ms` 1500/0–5000, `short_poll_interval_ms` 250/100–5000 | identical, floor-then-clamp (`configuration.rb:23`) |
| Base URL | http/https only, HTTPS except `LOCALHOST_HOSTNAMES`, trailing slash stripped | same host set, same rules (`configuration.rb:115`) |
| Credential | `getApiKey()` invoked immediately before each request; blank rejected | `secret_key` may be a callable, resolved per request (`client.rb:532`) |
| `POST /v1/jobs` body | `client_id`, `session_id`, `job_type`, `locale`, `slots_requested`, `prompt`, `slot_hint`, `overrides`; publisher merged `{...default, ...call}` | identical (`client.rb:129`) |
| Consent on the jobs route | only `overrides.gdpr_applies` | same, plus a warning naming any flag it cannot carry (`client.rb:458`) |
| Decision normalization | `normalizeV1Decision` — pending rule, no-fill triple, fill requires `format`/`asset_token`/`cs_declaration`/`constraints`, `dimensions` key must be present, 300×250 / 3000 ms defaults, native needs title+image_url, non-native needs `delivery_url` | line-for-line port (`decision_normalizer.rb`) |
| Polling ladder | 2 long polls (polling mode) → short polls ×1.5 backoff capped 2 s + 0–99 ms jitter, `min(120, ceil(budget / interval))` attempts | identical constants and order (`client.rb:52`, `client.rb:265`) |
| Long-poll wiring | `?wait_ms=` sent only when > 0; per-request timeout `timeout_ms + wait_ms` | same (`client.rb:144`) |
| `Retry-After` | non-negative delta-seconds → HTTP-date → 1 s default | same fall-through, expressed in seconds (`client.rb:399`) |
| Beacon success | HTTP 204 or empty body → `{accepted: true, reason_code: "OK"}` | same (`client.rb:193`) |
| Canonical enums | beacon event, generation event, `job_type`, position/format, consent decision/source | all five identical |
| Fail-silent core | public methods never throw; failures go to `onError` + logger; an observer that throws is swallowed | same at `Facade` + the polling ladder (`facade.rb`, `client.rb:297`) |
| Browser payload | endpoint returns the wavebird response shape; renderer resolves `placement.render.frame_url` | same shape on both delivery modes since #017 (`slot_payload.rb:111`) |
| Response size cap | 64 KiB | same constant (`client.rb:31`) |

## 2. Divergences already decided and recorded

No change from `docs/parity.md`; listed here only so the picture is complete.

| Aspect | Upstream | Gem | Record |
|---|---|---|---|
| Error posture | never throws; `WavebirdSdkError` machine codes | `Client` raises typed errors, `Facade` restores fail-silent | #003 |
| Decision transport | WS ticket → per-slot socket, polling as fallback | polling only, plus ActiveJob + Turbo Stream async mode, session-scoped | #001, #015, #016 |
| `callback` delivery mode | supported | not ported | #004 |
| Legacy wrapper transport | `/public/wrapper/v1/*` ingress, beacons, WS ticket | canonical-only | parity.md |
| Unknown beacon type | mapped to `null`, falls back to the legacy endpoint | rejected locally with `ArgumentError` before the request | #005 |
| `prompt.text` | accepted | no parameter accepts user text; `topic:` only | parity.md |
| `overrides` | ~12 typed sub-keys | one free-form Hash merged over `default_overrides` | parity.md |
| Non-finite numeric config | silently falls back to the default | raises `ConfigurationError` | parity.md |
| `asset_token → slot_id` memo | remembered to backfill beacon `slot_id` | not ported; `slot_id:` is required | parity.md |
| Consent defaults | injects none | injects none | #013 |
| UI surface | React / `mount` DOM builders (deprecated upstream), consent dialog, TCF | hidden `<section>` + Stimulus + hosted `render.js` | #006, #008, #009 |

## 3. Open findings — divergences not recorded anywhere

Ordered by how much they can bite a host app.

**F1–F4 were fixed on 2026-08-05** (branch `parity-fail-silent`, decision #018);
their "Options" paragraphs record what was chosen. F5–F7 remain open. F8 and F12
were documentation-only and are also done.

### F1 — Only 4 of 9 client methods have a fail-silent path — **fixed**

**Upstream.** Every public method of `WavebirdClient` is fail-silent.
`reportGeneration` is explicitly documented `@throws Never. Failures are
reported through onError.` (`wavebird-client.ts:1008`), and its body is one
`try` around the whole request (`wavebird-client.ts:1010`).

**Gem.** `Facade` wraps `create_placement`, `create_job`, `await_decision`,
`record_beacon` (`facade.rb:44`–`facade.rb:87`). `report_generation`,
`record_consent`, `activate_browser`, `project_config` and the single-poll
`decision` exist only on the raising `Client` — there is no non-raising way to
call them, and `Facade` has no `method_missing` delegation.

**Impact.** `report_generation` is the one upstream expects to be called inside
the host's generation loop. In the gem the only available call raises on a
wavebird outage, i.e. the ad path can take down a chat turn — the outcome #003
and #016 both promise it never causes. The README documents the 4/9 split as
intentional; `docs/parity.md` never flags it as a divergence from upstream.

**Resolved — option (a).** All five are on `Facade`: `report_generation` → `false`
on failure, `record_consent` / `activate_browser` / `project_config` → `nil`,
`decision` → pending decision. `ArgumentError` still propagates at both layers,
since a bad enum is a caller bug (upstream rejects it at compile time).

### F2 — HTTP 429 on job creation is an error here, a value upstream — **fixed**

**Upstream.** `createJob` treats 429 as a *successful* outcome of a different
shape: it returns `{error: "rate_limit_exceeded", retry_after_ms}`
(`wavebird-client.ts:952`), logs at `warn`, and deliberately does **not** call
`onError`. The public return type is the union
`JobResponse = AcceptedJobResponse | RateLimitedJobResponse` (`types.ts`).

**Gem.** `Client#create_job` raises `RateLimitedError` (carrying `retry_after`,
`client.rb:389`); `Facade#create_job` reports it through `on_error` and returns
`nil` (`facade.rb:57`).

**Impact.** At the facade — the public default — a rate limit is
indistinguishable from a network failure, and `retry_after` is lost. The engine
endpoint therefore falls back to a blocking placement on a rate-limited async
job, which will usually be rate limited too.

**Resolved — options (a) + (b).** `Facade#create_job` returns
`Types::RateLimited` (`error`, `retry_after` in seconds, `rate_limited?`), logs
at `warn`, and does not notify `on_error`. `Types::AcceptedJob` answers
`rate_limited?` too, so the union is discriminated by value, not by class. The
engine endpoint hides the slot on a rate limit instead of falling through to the
blocking path, which would spend the next 429 on the same slot. `Client` still
raises `RateLimitedError` — decision #003 is unchanged.

### F3 — Decision-timeout fallback has a different status — **fixed**

**Upstream.** Budget exhausted → `onError(sdk_decision_timeout)` and
`fallbackDecision(slotId)` = `{slot_id, fill: null, status: "pending"}`
(`wavebird-client.ts:171`, `wavebird-client.ts:1215`). The caller is told "still
pending", not "no fill".

**Gem.** `Facade#await_decision` returns `status: "ready", fill: false`
(`facade.rb:100`) — a *final* no-fill.

**Impact.** For the async broadcast path the visible outcome is the same (hide
the slot), so this is mostly a contract question: a caller that distinguishes
"poll again later" from "the auction is over" gets the wrong answer. There is
also a doc inconsistency: `errors.rb:46` states the facade "converts it back to
a pending outcome", which the code does not do.

**Resolved — option (a).** `Facade#await_decision` and `Facade#decision` return a
pending decision, matching `fallbackDecision`. Rendering is unchanged: pending is
not a fill, so `SlotPayload` still answers `{fill: false}` and the slot hides.
The `errors.rb` comment now describes exactly this.

### F4 — Beacon failure returns `nil`, not a shaped fallback — **fixed**

**Upstream.** `sendBeacon` failures resolve to
`{accepted: false, reason_code: "SDK_FAIL_SILENT"}` (`wavebird-client.ts:179`),
so the caller always gets a `BeaconResponse` and can read `accepted`.

**Gem.** `Facade#record_beacon` returns `nil` (`facade.rb:82`).

**Impact.** Callers must nil-check instead of calling `accepted?`; the
`SDK_FAIL_SILENT` reason code has no equivalent. Low severity — beacons are an
escape hatch here, since the hosted renderer sends its own.

**Resolved — option (a).** `Facade#record_beacon` returns
`{accepted: false, reason_code: "SDK_FAIL_SILENT"}` as a `Types::BeaconResult`,
so callers read `accepted?` rather than nil-checking.

### F5 — `create_placement` cannot send `topic` or `locale` — **fixed**

**Upstream.** The canonical job body carries `locale` and `prompt.topic`
(`wavebird-client.ts:385`).

**Gem.** `Client#create_job` exposes `topic:` and `locale:` (`client.rb:129`);
`Client#create_placement` — the primary, docs-recommended path — exposes
neither (`client.rb:98`). The engine endpoint uses `create_placement` in the
blocking default, so a host on the default path cannot send a topic hint at all.

**Impact.** The semantic-targeting hint the gem *does* allow is unavailable on
the path most hosts use. Defensible: the integration brief's `/v1/placements`
example body lists only `client_id`, `session_id`, `job_type`,
`slots_requested`, `slot_hint`, `overrides`, `consent`
(`docs/upstream/llm-integration-brief.md:98`) — neither field appears. But the
asymmetry between our own two methods is untracked.

**Resolved — option (a), after verifying against the sandbox (2026-08-05).** The
docs never state the placements request schema, so it was settled empirically
with the `sk_test_` key, using controls so a `200` could not be mistaken for the
API silently ignoring an unknown key:

| Body | Result |
|---|---|
| baseline (what the gem sent before) | `200`, `status: "ready"` |
| `+ locale: "en-US"` | `200` |
| `+ prompt: {topic: …}` | `200` |
| `+ both` | `200` |
| control: `+ zzz_not_a_real_field` (top level) | `400 validation_error` |
| control: `+ prompt: {zzz_not_a_real_field}` | `400 validation_error` |

The route validates strictly at both levels, so the accepted fields are really
accepted. `create_placement` now takes `topic:` and `locale:`, building the same
`prompt: {topic:}` shape as `create_job`.

**Deliberately left out:** the engine endpoint still does not accept a `topic`
from the browser, and no `default_locale` config was added. Upstream builds
`prompt.topic` from a server-side caller argument; the only place a page supplies
one is the Script Tag, a different trust model (origin-bound publishable key, no
secret). A per-turn topic therefore belongs in a host's own controller call.

**Also learned, fetching the Script Tag (`https://wavebird.ai/wavebird.js`):** it
uses `/v1/jobs` + `/v1/decisions/{slot_id}` — never `/v1/placements` — with the
legacy wrapper ingress body shape (`chat_session_id`, `slot_config`,
`delivery: {mode: "polling"}`). So wavebird's own second-tier integration runs
the same create-job-then-poll route this gem ports, and the Script Tag says
nothing about the placements schema.

### F6 — No deprecation warning for legacy `timing` values — **fixed**

**Upstream.** `timing: "before" | "after"` triggers a one-time
`warnSdkDeprecation` naming `"during"` as the recommended value
(`wavebird-client.ts:269`).

**Gem.** `timing` rides inside the free-form `overrides` Hash, so nothing
inspects it — a host on deprecated timing is never told.

**Resolved — option (a), 2026-08-05 (decision #020).** `Wavebird::Deprecation`
ports `deprecation.ts`: announce once per process, keyed as upstream keys it
(`stage3Timing:before`), through `config.logger` instead of `console.warn`. The
check runs on the *merged* overrides inside `Client#merged_overrides`, so a
timing set once in `config.default_overrides` is caught as readily as a per-call
one, and both endpoint methods are covered. The value is still sent — only
wavebird decides what it means.

Rated higher after `docs/upstream/sandbox-placements-example-2026-08-05.txt`
turned up: the example wavebird's own sandbox site generates carries
`"timing": "before"`, so a host copy-pasting it would otherwise never learn the
value is deprecated.

### F7 — Placement/render descriptors are not validated — **fixed, differently than proposed**

**Upstream.** `normalizeWavebirdPlacement` (`placement.ts`) validates before
handing anything to a renderer: a `render` block is dropped entirely unless
`strategy === "hosted_frame"` **and** `frame_url`, `script_url`, `media_type`,
`width`, `height`, `aspect_ratio`, `label_text` are all present and well-typed;
`ad_label_text` defaults to `"Sponsored"`; `width`/`height` default to `0`;
`format`/`asset_token` are required or the placement is `null`.

**Gem.** `Types::Placement` / `Types::Render` are tolerant pass-throughs
(`types.rb:140`, `types.rb:163`), and `SlotPayload.from_render` forwards any
render block that carries a `frame_url`, compacting the rest away
(`slot_payload.rb:111`). A partial descriptor reaches the browser instead of
being rejected server-side.

**Impact.** Small in practice — `render.js` re-derives what it needs and
defaults `label_text` itself — but it is a real difference in where the contract
is enforced, and it is the class of gap that hid #017.

**Resolved 2026-08-05 (decision #021) — neither option as written.** Option (a)
turned out to be wrong, and finding out why is the value of this finding.

`normalizeWavebirdPlacement` is not on the path this payload feeds. The hosted
renderer resolves a response with `placementFrom` → `renderFrom`, and
`renderFrom` requires **only** `frame_url`, deriving everything else
(`num(p.width)||300`, `aspect_ratio` from `w/h`, `p.ad_label_text||'Sponsored'`).
`startTurn` uses that path too. The strict helper is for callers who render
placements themselves — which this gem does not do. Porting its completeness
rule would have made us *stricter than the renderer*, hiding ads it could have
painted: a lost-fill bug introduced in the name of parity.

What was actually wrong was the opposite end. A fill the payload could not render
— no render block, or a blank `frame_url` — was reported as `{fill: true}` with
nothing attached. That is a shape the renderer discards (`startTurn`'s
`if(!p||!p.render)` → `clearPlacement`), so the slot stayed empty while the
endpoint claimed a fill: the same class of silent, unactionable payload as #017.

Fixed: an unrenderable fill is now `{fill: false}` on both paths, `frame_url` and
`asset_token` are read with upstream's `readString` semantics (a blank string is
absent, so no frame URL can end in a bare slash), and everything past `frame_url`
is still passed through as the API sent it — wavebird's own script decides the
rest.

### F8 — `x-csl-wrapper-version` value, and an extra `User-Agent`

**Upstream.** `DEFAULT_WRAPPER_VERSION = "sdk"` (`runtime-constants.ts`); no
explicit `User-Agent`.

**Gem.** `wavebird-rails/{VERSION}` on both `x-csl-wrapper-version` and
`User-Agent` (`client.rb:367`).

**Status — fixed 2026-08-05 (doc only).** `docs/parity.md:28` carried the open
caveat *"Verify server accepts arbitrary values; else mirror `sdk`"*. The
2026-08-04 live sandbox run rendered a real ad through `create_placement` with
this header set, so the caveat is answered: **the doc was stale, not the code.**
The parity row now records the verification and the fact that the value also
goes out as `User-Agent`. No behavior change.

### F9 — Transport mechanics differ in two small ways

**Upstream.** Node's `timeout` option is an *idle* timeout, and the 64 KiB cap
is enforced mid-stream: the request is destroyed as soon as the threshold is
crossed (`wavebird-client.ts:740`).

**Gem.** Faraday's `options.timeout` is a *total* deadline (`client.rb:326`),
and the cap is checked after the whole body has been read (`client.rb:416`) and
is not applied at all to error envelopes (`safe_parse_hash`, `client.rb:425`).

**Impact.** A slow-drip response is cut off by us and tolerated by upstream (our
behavior is the safer one); an oversized *error* body is fully buffered and
parsed here. Both are edge cases.

**Options.** (a) Leave, record as a transport-layer difference. (b) Also cap
`safe_parse_hash`.

### F10 — Logging is a warn-only string channel

**Upstream.** `createSdkLogger` (`logging.ts`) offers `silent|error|warn|info|
debug` levels, a default console logger, and structured metadata on every entry
(`client`, `operation`, `path`, `slot_id`, `code`, `retry_after_ms`), with
throwing loggers swallowed.

**Gem.** A single `config.logger&.warn("[wavebird] Class: message")`
(`facade.rb:113`, `client.rb:303`). No level control, no structured meta —
though `ActiveSupport::Notifications` (`wavebird.request`, `client.rb:342`)
covers part of what upstream's `info`/`debug` levels are for, which upstream has
no equivalent of.

**Options.** (a) Add `config.log_level` and structured meta. (b) Record as
adapted: Rails hosts filter by logger level and subscribe to notifications.

### F11 — `revenue_estimate: null` is dropped rather than preserved

Upstream keeps an explicit `null` (`wavebird-client.ts:566`); the gem includes
the key only when it is a Hash (`decision_normalizer.rb:144`). In Ruby the
member reads `nil` either way — noted for completeness, no action suggested.

### F12 — Documentation drift — **fixed 2026-08-05**

All three were documentation-only; no behavior changed, and the suite is
unaffected (379 examples green, RuboCop and YARD clean after the edits).

- `README.md:166` — the `create_job` row omitted `consent:`, added in #014.
  Now listed, with a note that this route carries only `overrides.gdpr_applies`
  and that `create_placement` takes the full object.
- `docs/parity.md:28` — the `wrapper_version` "verify" caveat, answered by the
  2026-08-04 live sandbox run. Row now records the verification (see F8).
- `lib/wavebird/errors.rb` — the `DecisionTimeoutError` comment claimed the
  facade converts a timeout "back to a pending outcome"; it returns a ready
  no-fill. Comment now states what the code does and points at F3.

Note the ordering with F3: if F3 is resolved toward matching upstream (return a
pending decision), this comment changes again — it now describes the current
behavior, not a decision to keep it.

## 4. Not ported, and beyond upstream

**Not ported** (all deliberate, see §2): WebSocket decision transport ·
`callback` delivery · legacy `/public/wrapper/v1/*` routes and the legacy beacon
fallback · `./browser` client and `browser-verification` · `./consent` (dialog,
store, TCF strings, React bindings) · `WavebirdAd.tsx` / `mountWavebirdAd`
(deprecated upstream) · `resolveAdTimingPlan` (deprecated upstream) ·
`public_contracts/ssp.ts`.

**Beyond upstream** (gem-only, by design): `create_placement`
(`POST /v1/placements`) · `record_consent` · `activate_browser` ·
`project_config` · the mounted engine endpoint, Stimulus controller and
`wavebird_slot` helper · async Turbo Stream delivery · boot-time reachability
guards · `ActiveSupport::Notifications` instrumentation · the typed error
hierarchy · local enum validation on beacons/consent/generation events.

## 5. Verdict

The wire contract, response normalization, timing budgets and the fail-silent
core were already at parity. Everything found sat in the Ruby-side ergonomics of
the fail-silent layer: five methods with no non-raising path (F1) and three
fallback *values* differing in kind from upstream's (F2, F3, F4).

**Status after 2026-08-05: every actionable finding is closed.** F1–F4 under
decision #018, F5 under #019, F6 under #020, F7 under #021 (which reversed the
fix this document originally proposed — see the finding), F8 and F12 as
documentation. F9–F11 are noted-not-actioned: two edge-case transport mechanics
and one immaterial `nil` handling, none of which change observable behavior.
