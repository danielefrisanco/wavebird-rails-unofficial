# wavebird-rails — Plan v3: the hosted renderer moved under us

Written 2026-08-23, after `examples/chat_react.rb` was driven in a real browser
and the sponsored slot never requested a placement. Plan v2 is complete (items
A–G, decisions #024–#029); this supersedes nothing in it.

> **One-line summary.** wavebird changed `render.js` after our 2026-07-18
> snapshot. Every browser turn now requires an `authoritative_consent` object the
> gem does not send, so `startTurn` returns without calling our endpoint — no
> request, no error, no console output. **The gem's browser integration does not
> work against the live renderer**, and 499 green examples did not notice.

---

## Status — 2026-08-23

| | Item | State |
|---|---|---|
| 0 | Refresh the snapshot | ✔ **done** — `render-js-snapshot-2026-08-23.js`, old one kept |
| **A** | Send `authoritative_consent` | ✔ **done 2026-08-23** (#030) — verified against the live renderer |
| **B** | Make renderer drift detectable | ✔ **done 2026-08-23** (#031) |
| C | Close #023 (`click_url` now validated) | ✔ **done 2026-08-23** (#033) |
| D | Record the legacy beacon route | ✔ **done 2026-08-23** — `docs/parity.md` |
| E | `.env.test` placeholder | Daniele's |

**Every item is done.** A (#030) restored the browser integration, B (#031) makes
the next change of this kind detectable, C (#033) and D are recorded. E is
Daniele's and is not a gem concern.

**One decision came out of the investigation rather than the plan:** #032 keeps
the API's `reason_code`, `hint`, `expected_shape` and `fields`, which the gem was
discarding. Everything diagnosed in item E below was read from fields that had
been thrown away — the sandbox debugging that produced this plan took a dozen
probes for information that was in the first response.

**A is done** (#030). Daniele chose `config.authoritative_consent`, a callable
resolved per slot render. The blocking path carries it through the browser
(`data-wavebird-consent-value` → every documented JS path → `withTurn`); the
async path carries it inside the placement payload and needed no JavaScript at
all. `docs_turn_body_contract_spec` now guards all six documented turn-starts,
checking the neighbourhood of the `withTurn` call with comments stripped —
two weaker versions of that guard passed with the code deleted.

**Verified against the live renderer, which is the only proof that counts here.**
Before: `POST /wavebird/sponsor_slot` absent from the network trace. After: the
request fires, the gem calls wavebird, and the status panel reports wavebird's
own answer. The remaining `"Consent is not current"` is the **server-side**
consent story (item E), not this gate.

**Known-broken, deliberately visible:** `render_js_contract_spec` has a `pending`
example asserting the stand-in tracks the newest snapshot. It fails today and is
meant to. Remove the `pending` when B lands.

**Release blockers cleared.** A and B are both done. What remains (C, D) is
recording only, and E is Daniele's. Run `rake render_js_drift` before tagging.

---

## How this was found, and why that matters more than the bug

The bug is a missing field. The reason it survived is the part worth fixing.

`examples/chat_react.rb` was verified end-to-end in headless Chrome: React
rendered, a message was sent, a reply came back, the status panel read
**"render.js loaded"**. That was reported as working. It was not. `withTurn`
*had* loaded and *had* run — and done nothing, because the consent gate rejected
the turn silently. The chat worked; the ad path was inert.

It only surfaced because a network trace showed `POST /wavebird/sponsor_slot` was
never sent. Nothing else in the repo could have told us:

| Layer | Says | Actually proves |
|---|---|---|
| 472 unit examples | green | our Ruby matches our Ruby |
| 27 system examples (headless Chrome) | green | our Ruby matches **our own stand-in** |
| `render_js_contract_spec` | green | the four entry-point *names* still exist |
| `examples/*` booted for real | green | the page serves and the endpoint answers |

**`spec/dummy/public/v1/render.js` is a hand-written stand-in of the real
renderer.** It was written to consume what we produce. #012a introduced it, #017
already caught it once — the stand-in wrapped our flat payload before reading it,
so the suite checked our assumption against itself and a real browser found the
bug in ninety seconds. The same shape recurred here, one layer up: the stand-in
implements the contract *as of the snapshot*, so a vendor change is invisible by
construction.

`render_js_contract_spec` was the designated guard and it pins the wrong thing —
`withTurn`, `startTurn`, `renderPlacement`, `clearPlacement` are all still
present and still exported. **The names did not change. The preconditions did.**

---

## Verified findings

Everything below was read out of the live file
(`https://api.wavebird.ai/v1/render.js`, fetched 2026-08-23, 16 300 bytes)
and diffed against `docs/upstream/render-js-snapshot-2026-07-18.js` (12 484
bytes). Eleven functions added, **none removed**.

### 1. The consent gate — blocking, and the whole reason nothing works

```js
api.startTurn = function (input) {
  var opts = readTurnOptions(input);
  ...
  if (!consentAllowsAdActivity(opts.authoritative_consent)) {
    return { id: uuid(), target: target,
             decision: Promise.resolve(null),      // <- no fetch, ever
             finish: function () { return Promise.resolve() },
             cancel: function () {} };
  }
```

`readTurnOptions` takes `authoritative_consent` **only from the turn options** —
there is no global, no `api.setConsent`, no fallback. Required shape:

| Field | Rule |
|---|---|
| `lifecycle_state` | must equal `"granted"` |
| `revision` | safe integer, `>= 1` |
| `updated_at_ms` | safe integer |
| `expires_at_ms` | safe integer, `> Date.now()` |

It may be the object itself **or a function returning it** —
`resolveAuthoritativeConsent` calls it inside a `try`.

**It is a purely local check.** `consentAllowsAdActivity` makes no network call
and the object is never sent in any request body. So this is the **host
asserting** consent to the renderer, not the renderer verifying it with wavebird.

**It gates four points, not one** — found by `render_js_contract_spec` failing on
the refreshed snapshot, not by reading:

1. `startTurn`, before the fetch — returns a null decision, no request.
2. `startTurn` again, *after* the fetch resolves — `clearPlacement`, so a
   placement that was fetched still gets thrown away.
3. `renderPlacement` itself — `clearPlacement` and return `null`.
4. `sendRenderBeacon` / `sendBeacon` — no beacon fires.

**Point 3 means async delivery mode is broken in exactly the same way.** The
Turbo Stream reveal calls `renderPlacement` directly (#009), so the placement
arrives, the stream fires, and the slot is cleared instead of shown.

**But point 3 also hands us the cleanest fix**, and it was not visible before the
snapshot refresh:

```js
var authoritativeConsent = options && options.authoritative_consent
                        || p && p.authoritative_consent;
```

`renderPlacement` takes the consent object **from the placement payload** when
the caller did not pass it. `p` is `placementFrom(options)` — the payload the
gem's own `SlotPayload` builds. So the async reveal can be fixed **entirely
server-side**, with no JavaScript change at all: put `authoritative_consent`
inside the placement and the existing reveal works.

`startTurn` has no such fallback — it reads only `readTurnOptions(input)` — so
the *blocking* path still needs the object passed in JS. That asymmetry is the
single most important fact for designing item A.

**That is the finding that makes this fixable.** No new API is required. The gem
does not need wavebird to hand it a consent record — it needs a way for the host
to state one and a path to carry it into `withTurn`.

### 2. There is no endpoint that returns this object

Checked, so nobody re-checks it:

- `POST /v1/consent` returns `consent_id`, `session_id`, `expires_at`,
  `normalized` — **none** of `lifecycle_state`, `revision`, `updated_at_ms`,
  `expires_at_ms`.
- `GET /v1/projects/{client_id}/config` carries `consent_mode`, no consent record.
- Seven plausible read paths all 404: `/v1/consent`, `/v1/consent/{session_id}`,
  `/v1/sessions/{id}/consent`, `/v1/consent/state`, `/v1/consent/current`,
  `/v1/projects/{id}/consent`, `/v1/browser/consent`.
- The Script Tag (`https://wavebird.ai/wavebird.js`, 32 KB) is a **separate
  integration**: it never calls `withTurn`/`startTurn`, keeps its own consent in
  `localStorage`, and authenticates to `/v1/consent` with a Bearer token from
  `/v1/browser/activate`. It contains none of `lifecycle_state`, `revision`,
  `authoritative_consent`.

Consistent with the local-check finding: the object is the host's to construct.

### 3. Undocumented, and versioning will not warn us

The [public changelog](https://wavebird.ai/api/changelog) still shows exactly one
entry ("2026 Q2"), unchanged since our snapshot. `upstream/wavebird` is still
`0.1.5`. The [consent docs](https://wavebird.ai/api/consent) describe *sending*
consent and never mention `lifecycle_state`, `revision` or `expires_at_ms`.

**The hosted renderer is served, not versioned.** It can change under every
integration at any time, with no version to pin and no changelog entry. That is a
standing risk, not a one-off, and item **B** below is the response to it.

### 4. What else changed (verified, non-blocking)

- **`click_url` is now validated.** New `clickUrl()` rejects anything whose
  protocol is not `http:`/`https:`, plus URLs carrying credentials, plus
  malformed escapes. **This resolves decision #023**, which accepted an
  unvalidated `javascript:` click-through as upstream's risk to hold and said
  "if wavebird ever documents the guarantee, this is the row to revisit."
  It did not document it — it implemented it.
- **Render lifecycle tracking** — `setRender`/`getRender`/`clearRender`/
  `isRenderActive`/`cleanupRender`/`cleanupTurnRender`. Internal; beacons are now
  gated on `isRenderActive()`.
- **`sendRenderBeacon`** posts to **`/public/wrapper/v1/beacons`** with
  `contract_version: "csl_wrapper_beacon/v1"` — the *legacy wrapper* route. The
  hosted renderer uses the legacy beacon path. Does not affect us (we never
  beacon from the browser) but it belongs in `docs/parity.md` next to #005 and
  #024/#025, because it is evidence about where wavebird's own boundary sits.
- **`placementFrom` and `renderFrom` are byte-identical** to the snapshot. So
  `SlotPayload`'s shape (#017, #021) is still correct and needs no change. The
  only thing wrong is the missing precondition.
- **`startTurn`'s call into `renderPlacement` gained an argument** —
  `{target, decision, authoritative_consent}`. The response is still handed over
  whole, so this is a new precondition rather than a resolution change.
  `render_js_contract_spec` pinned the *entire* call and so reported it as an
  #017-class resolution break; the pin is now scoped to the part #017 needs
  guarded.

---

## Items

### ❗ A. Carry `authoritative_consent` into the turn — **the fix**

Nothing else restores a working browser integration.

**What has to move:** the host's consent state → the slot → `withTurn(...)`, on
all four paths the gem documents (Stimulus controller, plain JS, React hook,
generator snippet), plus the async `DecisionPollJob` path.

**Needs Daniele's decision — where does the object come from?**

1. **`config.authoritative_consent`**, a callable resolved per request, returning
   the hash. Matches `secret_key`'s callable convention and
   `before_send_text` (#028). Server-side, one place, testable.
2. **Per-slot:** `wavebird_slot(authoritative_consent: ...)`. More flexible, more
   for a host to remember, and easy to forget on one slot.
3. **Host-supplied in JS only** — the gem documents the field and forwards
   whatever the page passes. Least gem surface; leaves every host to build it.
4. **Derive it from `record_consent`.** *Not viable as the only route* — the
   response has none of the four fields (finding 2). Could only ever be a
   convenience wrapper over an assertion we invent, which is worse than asking
   for it plainly.

**Recommendation: 1, with 3 documented as the escape hatch.** A Rails host that
runs a CMP has this state server-side already; a callable lets it be resolved
per request without the gem storing consent. The helper then emits it into the
slot and all four JS paths read it from one place — the same shape as
`session_id`, `position` and `mode` today, which `docs_turn_body_contract_spec`
already keeps in step across every copy.

**Open questions inside that:**

- [ ] Is a **missing** consent object a warn-and-degrade (like #016's missing
      `session_id`) or a raise? Consistency says warn: the slot simply stays
      empty, which is what happens today anyway — but *silently*, which is the
      complaint. It should at minimum log once.
- [ ] Does it belong in the **turn body** as well, or only in the turn options?
      The renderer never sends it, so the server would only be able to log it.
- [ ] `revision` and `updated_at_ms` are a CMP's vocabulary, not wavebird's. Does
      the gem define defaults (`revision: 1`, `updated_at_ms: Time.now`) or
      require all four? Defaults make it easy to assert consent nobody gave.
- [x] ~~**Async mode**: check whether the reveal path is gated too.~~
      **Answered: yes, and it has a server-side fix.** `renderPlacement` gates on
      consent, so async is broken identically — but it falls back to
      `p.authoritative_consent`, i.e. the placement payload. `SlotPayload` can
      carry it and the async path needs no JS change. See finding 1.
- [ ] Given that asymmetry, decide whether the **blocking** path should also read
      consent from the payload for symmetry — it cannot, `startTurn` has no
      fallback — or whether the gem accepts that the two paths get it from
      different places and documents why.

### ❗ B. Make renderer drift detectable — **do this before or with A**

Without it, A is one lucky fix and the next vendor change is silent again.

- [ ] **Refresh the snapshot** to `docs/upstream/render-js-snapshot-2026-08-23.js`
      and keep the old one. The diff between them *is* the evidence for this plan.
- [x] ~~**Stop hand-writing the stand-in.**~~ **Done, by a different route than
      proposed.** Generating it was rejected: the real file is minified, carries a
      NUL byte, and beacons to a blocked host, so a generator would be a second
      thing to keep honest. Instead the stand-in now **ports every gate** the
      snapshot enforces, and a spec compares the two sets, so the hand-written
      part can no longer silently omit a precondition. Porting the consent gate
      immediately caught two real gaps the old stand-in could not see: the dummy
      app had no consent configured, and its path C used the bare-selector
      `withTurn` form — which **can no longer work at all**, since `render.js`
      reads consent only from an options object. INSTALL.md documented that form;
      now corrected.
- [x] ~~**Make `render_js_contract_spec` assert preconditions, not names.**~~
      **Done.** It extracts every helper the snapshot negates inside a guard
      (`if(!x(`) and requires the stand-in to *define* each one. Justified
      omissions live in an explicit `UNIMPLEMENTED_GATES` allowlist with reasons,
      so skipping a gate is a decision someone wrote down rather than an omission
      nobody noticed. Verified in both directions: a gate added upstream is named,
      and a gate deleted from the stand-in is named. Matching on definitions, not
      calls — the first version scanned calls and passed with the function body
      deleted.
- [x] ~~**A staleness check.**~~ **Done: `rake render_js_drift`.** Refetches the
      hosted file and fails if it differs from the newest snapshot, telling the
      reader to save a dated copy and let the contract spec name what broke.
      Deliberately **not** in the default gate: it needs network, and `rake` must
      stay runnable offline. Run it before tagging a release. Wiring it into CI is
      the obvious follow-up and is left as a choice rather than assumed.
- [ ] **At least one automated test against the real renderer.** Still open, and
      the honest residual gap. `rake render_js_drift` detects that the file
      *changed* and the contract spec says which gate appeared, which together
      would have caught this one — but nothing yet drives the genuine `render.js`
      in a browser and asserts a turn reaches the endpoint. That was done **by
      hand** for #030 (headless Chrome over the DevTools Protocol, watching for
      `POST /wavebird/sponsor_slot`), and by hand is how it stays until this is
      built. Needs network and a browser, so it belongs beside `spec:system` as
      its own task, never in the default gate.

### C. Resolve #023 — `click_url` is now validated upstream

- [ ] Record that the accepted risk is closed: the renderer enforces
      `http:`/`https:`, rejects embedded credentials and malformed escapes. #023
      said this row should be revisited if wavebird ever addressed it. It has.
- [ ] Re-read the decision's conclusion. It argued against adding our own
      allowlist because it would make us *stricter than the renderer we feed*.
      That reasoning holds and the answer is unchanged — but the risk it was
      weighing is gone, and the entry should say so rather than reading as an
      open exposure.

### D. Record the legacy beacon route in `docs/parity.md`

- [ ] The hosted renderer beacons to `/public/wrapper/v1/beacons`. Small, but it
      is direct evidence about the canonical/legacy boundary that #024 and #025
      reason about, and #005 already discusses `sendBeacon`'s wrapper fallback.

### E. Not a gem issue — `.env.test` is holding a placeholder

`WAVEBIRD_CLIENT_ID` is set to `wbproj_your_client_id`, the example placeholder,
not a real project id. Independent of everything above, and it means no sandbox
run in this repo has been exercising a real project. Worth fixing before using
sandbox results as evidence for anything.

Related: `project_config` reports `consent_mode: "wavebird_consent"` for that id
— the project expects consent collected through **wavebird's own dialog**, while
the gem records `source: "publisher_custom"`. That is the server-side half of the
same consent story, and it is why `create_placement` answers "Consent is not
current". Check the dashboard setting before concluding anything from item A.

---

## Suggested order

0. ~~**Refresh the snapshot**~~ — **done 2026-08-23**,
   `docs/upstream/render-js-snapshot-2026-08-23.js`, kept alongside the old one.
   It immediately earned its place: the refresh made `render_js_contract_spec`
   fail, and that failure is what surfaced the `renderPlacement` consent gate and
   its payload fallback — both missed on a first read of the same file.
   `render_js_contract_spec` now carries a **pending** example asserting the
   stand-in tracks the newest snapshot, so the drift is recorded in the suite and
   not only in this document. Remove the `pending` when B lands.
2. **A**, once Daniele has picked where the consent object comes from.
3. **B's remaining guards**, so A cannot silently rot.
4. **C** and **D** — recording only, no code.
5. **E** is Daniele's, whenever.

**Do not ship a release before A.** The gem currently installs cleanly, passes
its gate, serves its endpoint, and never shows an ad.

## How to work this plan

**Do not trust the stand-in.** It has now produced two false green suites (#017,
and this). Any claim about browser behaviour needs the real renderer or a real
browser behind it.

**"Loaded" is not "worked".** `Boolean(window.wavebird?.withTurn)` was the check
that reported success here. It proved the script parsed. Assert the *effect* —
a request, a rendered frame — never the presence of a function.

**The vendor moves without telling us.** No version, no changelog entry, no doc
update. Anything derived from a snapshot is true only as of its date, and every
decision resting on one should say which date.
