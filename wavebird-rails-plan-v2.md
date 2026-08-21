# wavebird-rails — Plan v2 (post-1.0 questions)

Companion to [wavebird-rails-plan.md](wavebird-rails-plan.md), which is complete
through Phase 10.5. Nothing here is started. Raised by Daniele, 2026-08-11.

Seven items. Two of them (**A**, **E**) are *questions to answer* before any code
is justified; four are work with a shape already visible; one is a correction.

Every item that reverses an approved decision needs its own `docs/DECISIONS.md`
entry **before** implementation — WAY_OF_WORK rule 4. Those are flagged.

**Parked branches.** One item has speculative work already on a branch, written
before the plan was agreed and left unmerged on purpose:

| Branch | Item | State |
|---|---|---|
| `rename-poll-decision` (`4aff31a`) | **E** — the `decision` anomaly | Green, unreviewed, no CHANGELOG or decision entry |

A green branch is not an approved one. Read the diff before merging any of these;
the suite passing says the change is consistent, not that it is right.

---

## Verdicts at a glance

| | Item | Verdict | Why |
|---|---|---|---|
| **A** | WebSocket transport | ❌ **No** | Ticket endpoint is wrapper-only. Building it means adopting the legacy transport wholesale |
| **B** | `callback` delivery | ❌ **No** | `callback_url` forces the legacy ingress body. Same boundary, same answer |
| **C** | `slot_id` memo | ❌ **Not now** | Mutable state in a long-lived Rails singleton, for ergonomics on a path most hosts never take |
| **D** | React | ✅ **Recipe + example** — ❌ not shipped components | The `withTurn` seam already exists. Components are what upstream shipped and then deprecated |
| **E** | `decision` rename | ✅ **Yes** — ❌ leave the other nine | The one real anomaly. Free until publication, breaking after |
| **F** | Redactor seam | ✅ **Yes** | The only way a host can filter the engine endpoint without monkey-patching |
| **G** | Test the examples | ✅ **Yes, first** | First thing a new user runs; least tested code in the repo |

**A and B are one question, not two features.** Both are unreachable for the same
structural reason, so the real decision is *"do we adopt the legacy wrapper
transport?"* — and answering it piecemeal is how a canonical-only client stops
being one. Neither is deprecated; see the correction below.

**Only E has a clock on it.** Everything else costs the same after publication.

---

## ⚠️ Correction first: `callback` mode is not deprecated

The brief for this plan assumed `callback` delivery was skipped because it is
deprecated, and generalised that to "anything deprecated we don't port". The
first half is wrong and the second needs qualifying.

**Verified 2026-08-11.** Nothing in `upstream/wavebird/src/` marks
`decisionDelivery: "callback"` as deprecated. Decision #004 records the real
reason: it was **not in the build prompt**, and it needs a publicly reachable
callback URL, which a localhost dev app does not have. It was approved as a
"later todo — design the client so it can slot in post-v1 without breaking
changes", not rejected.

**What upstream actually deprecates** (every `warnSdkDeprecation` call site):

| Deprecated | Where | What we did |
|---|---|---|
| The SDK as a whole — "now an advanced compatibility layer", use the Script Tag or REST API | `index.ts:5`, `browser.ts:5` | Why we port the **canonical REST contract**, not the SDK's legacy transport. Already the founding decision |
| `resolveAdTimingPlan` — "Stage 1 moves timing and delivery policy server-side" | `timing.ts:38` | Not ported |
| `overrides.timing: "before" \| "after"` | `wavebird-client.ts:269` | **Warning ported** (#020) — we do not refuse the value, we say what upstream says |
| React / `mountWavebirdAd` DOM builders | components | Not ported (#006). Relevant to item **D** below |

**So the rule is not "don't port deprecated things".** It is closer to: *port the
deprecation, not the deprecated behaviour.* We warn where upstream warns (#020),
and we decline to carry legacy transports the vendor is retiring. A feature being
absent from this gem is usually about the canonical/legacy boundary, not about
deprecation — and `callback` is absent for neither reason.

**Action:** none required, but item **A** and item **F** below should not inherit
the wrong premise.

---

## ❌ A. WebSocket decision transport — **DO NOT BUILD.** Record only

**Verified 2026-08-11.** `createDecisionWsTicket` requests

```
POST /public/wrapper/v1/slots/{slot_id}/decision-ticket
```

(`wavebird-client.ts:875`) — a **legacy wrapper route**. There is no canonical
`/v1/*` equivalent.

So introducing the WebSocket transport does not mean "add a socket". It means
adopting the legacy `/public/wrapper/v1/*` transport this gem excluded as its
founding decision — the same boundary that already keeps out
`predicted_latency_ms`, `model_id`, `verification`, `candidate_partner_ids` and
`prompt.token_count_estimate`. That is a much larger question than the transport
itself, and nothing about the current design is waiting on it.

**Worth stating plainly because it is easy to misread:** the WebSocket is not
deprecated, and neither is the wrapper route. They are simply on the other side
of the canonical/legacy line we drew deliberately.

**What this does not settle.** Upstream's socket is per-slot — ticket, open, one
message, close — so it is scoped to a single caller *by construction*. That is
the property #015 had to rebuild by hand after the shared-channel leak. Our
session-scoped Turbo Stream now has it, but by convention rather than by
construction, which is a weaker guarantee. If that ever bites again, the fix is
to tighten our own scoping, not to import the wrapper transport.

- [ ] **Record as a closed question** in `docs/DECISIONS.md`: the WS transport is
  wrapper-only, therefore out of scope for a canonical-only client, and #001
  stands unchanged for a reason stronger than "we preferred polling".
- [ ] Amend the "Future — raised, not scheduled" entry in
  [wavebird-rails-plan.md](wavebird-rails-plan.md), which still frames this as an
  open design question with unknowns. It is not; the unknown is resolved.

## ❌ B. `callback` delivery mode — **DO NOT BUILD.** Record only, and supersede #004

**Verified 2026-08-11.** `callback_url` is an explicit *condition* of
`canUseCanonicalRequest` (`wavebird-client.ts:308–317`):

```ts
params.callback_url === undefined &&
```

Supplying it makes the check false and sends the **legacy wrapper ingress body**
instead. So the canonical `/v1/jobs` and `/v1/placements` routes have no position
for a callback URL, and a canonical-only client cannot express one.

This retires the premise this plan was written against. `callback` is **not
deprecated** — see the correction at the top — and it was not skipped for being
deprecated. It is unreachable for exactly the same structural reason as the
WebSocket: it lives on the legacy transport.

- [ ] **Supersede decision #004.** It reads as a deferred design task ("design the
  client so it can slot in post-v1 without breaking changes"), which implies the
  work is possible on our current route. It is not, and leaving #004 as written
  invites someone to attempt it. Record the finding and close it.
- [ ] Add `callback_url` to the "legacy-only request fields" paragraph in
  `docs/parity.md`, which lists the other five triggers but not this one.

**If callback delivery is ever genuinely wanted**, the question to ask is not
"port callback mode" but "do we adopt the legacy wrapper transport" — one
decision covering this, the WebSocket, and the richer consent flags together.
Answering it piecemeal is how a canonical-only client stops being one.

## ❌ C. The `asset_token → slot_id` memo — **DO NOT BUILD** unless a host asks

**Today.** `#record_beacon` requires `slot_id:`. Upstream keeps a private
`slotIdByAssetToken` map (`wavebird-client.ts:811`), populated in
`rememberDecisionAsset` on every ready+fill decision, and read by
`resolveBeaconSlotId` (`:899`) to backfill a beacon whose `slot_id` was omitted.

**What it actually is:** an ergonomic convenience, not a contract difference. The
wire body is identical either way — the question is only whether the *caller*
must supply a value the client could remember.

**Arguments against porting (why it was skipped):**

- It is per-client-instance mutable state in a gem whose client is otherwise
  stateless. In Rails that instance is typically a long-lived singleton shared
  across threads and requests, where upstream's is per-process in a
  single-threaded runtime. **A `Hash` mutated from multiple request threads is
  the actual risk here**, and it needs either a `Mutex` or a bounded thread-safe
  cache.
- Unbounded growth: one entry per fill, never evicted. Upstream has the same
  issue but a shorter-lived process.
- `#record_beacon` is documented as an advanced escape hatch — the hosted
  renderer beacons on its own. The ergonomics being optimised are for a path most
  hosts never take.

**Arguments for:**

- It is real upstream behaviour we do not have, and the parity table currently
  lists it as "not ported" without much justification.
- A host that *does* beacon manually has to thread `slot_id` through their own
  code alongside `asset_token`, which is exactly the plumbing the memo removes.

**If we do it:** bound it (an LRU with a small cap, or entries dropped after
first read), make it thread-safe explicitly, and keep `slot_id:` accepted so
nothing breaks. Decide whether it lives on `Client` or in a small collaborator —
a mutable cache inside `Client` is a meaningful change to that class's character.

**Recommendation:** low priority. Worth doing only if a real host asks. Record
the thread-safety reasoning either way, since "not ported" currently reads as an
oversight.

---

## ✅ D. React — **BUILD** the recipe and the example. **Not** the components

**Today.** Hidden `<section>` + Stimulus + hosted `render.js` (#006, #008, #009).

**Important framing:** upstream's own React bindings sit alongside `mount` DOM
builders that are **deprecated**, so "port what upstream has" is not the brief.
The question is what a React host app needs from a *Rails* gem.

**The seam already exists and is the whole point.** Path C —
`window.wavebird.withTurn({target, body}, work)` — is framework-agnostic, needs
no Stimulus, and is what the docs now lead with. A React integration sits on
that, not on the engine's Stimulus controller.

**What "ready for use on React" could mean, in increasing commitment:**

1. **A documented recipe** — a `useWavebirdTurn` hook written out in INSTALL.md,
   maybe 15 lines, that a host copies. No shipped JS, no build step, nothing to
   version. Matches how we already treat the plain path.
2. **A runnable React example** — `examples/chat_react.rb`, single-file like the
   other two, React from a CDN import map (the same trick `chat_hotwire.rb` uses
   for Stimulus). Shows the hook working end to end without adding a build
   toolchain to the gem.
3. **Shipped React components** in `app/javascript` — a real dependency on
   React's version matrix, JSX that needs a build step the gem does not have, and
   a surface to maintain. This is what upstream did and then deprecated.

**Recommendation: 1 and 2, explicitly not 3.** The gem's JS position has been
"own the seam, not the framework" since #006, and shipping components would
reverse it for the framework whose bindings upstream is itself retiring. A
runnable example proves it works; a hook recipe makes it copyable. Both are
consistent with the plain path leading the docs.

**Prerequisite:** the React turn must forward `session_id`, `position` **and
`mode`** in the body, exactly like the plain path — see
`docs_turn_body_contract_spec.rb`, and add the new example to its file list. That
spec exists because this precise field went missing once already.

**Reverses:** nothing, at options 1–2. Option 3 reverses #006.

---

## ✅ E. Surface size — **BUILD** the `decision` rename. Leave the other nine alone

**Daniele: "I feel it a bit strange."** Reasonable. Here is the whole picture.

Upstream's `WavebirdClient` public surface is **four** methods: `createJob`,
`getDecision`, `reportGeneration`, `sendBeacon`. Everything else
(`getDecisionViaWebSocket`, `getDecisionViaPolling`, `pollDecisionOnce`,
`sendLegacyBeacon`, `createDecisionWsTicket`) is private.

Ours is **ten**:

| Ours | Upstream equivalent | Why it exists |
|---|---|---|
| `create_job` | `createJob` | direct port |
| `await_decision` | `getDecision` | direct port — this is the ladder |
| `report_generation` | `reportGeneration` | direct port (#002) |
| `record_beacon` | `sendBeacon` | direct port |
| `create_placement` | — | `POST /v1/placements`, the **docs-recommended primary route**. Not in the SDK at all |
| `decision` | `pollDecisionOnce` (private) | we made a private upstream helper public |
| `record_consent` | — | `POST /v1/consent`, from the API docs |
| `activate_browser` | — | `POST /v1/browser/activate`, from the API docs |
| `project_config` | — | `GET /v1/projects/{id}/config`, from the API docs |
| `initialize` | `constructor` | — |

**So the ten decompose as:** 4 ported + 1 primary route the SDK lacks + 3
canonical endpoints the SDK never wrapped + 1 upstream private helper we exposed
+ the constructor.

**The one real anomaly — `decision` — and how to fix it:**

It is the only case where we *widened* upstream's encapsulation. Upstream keeps
its single-poll helper (`pollDecisionOnce`) private and exposes only the ladder,
because the ladder is the intended interface.

**The concrete failure this invites:** someone porting TypeScript that calls
`getDecision(slotId)` reaches for `decision(slot_id)`. In the SDK that is the
full ladder — two long polls, then backoff to the budget. In ours it is *one*
request. They get a pending decision, no error, and no clue why. A silent
behavioural difference behind a matching name. It has already caused a
documentation drift once (parity.md, fixed 2026-08-11).

- [ ] **Rename `decision` → `poll_decision`** on both `Client` and `Facade`.
  Small and contained: two definitions, one internal call site in the ladder, and
  the specs. Free right now — nothing is published — and not free later.

  > **A branch already exists: `rename-poll-decision` (`4aff31a`).** Written
  > 2026-08-11 and **not reviewed** — it is parked so the work is not lost, not
  > because it is ready. Suite is green on it (444 examples, 100% line + branch,
  > RuboCop clean, YARD 100%), but **do not merge it without settling the open
  > questions below**, and re-read the diff first: it was written in the same
  > sitting as the plan that proposes it, which is exactly the circumstance that
  > produced the missing `mode` in the generator.
  >
  > What it does *not* do: no CHANGELOG entry, no `docs/DECISIONS.md` entry.
  >
  > **Provenance, since it will not be obvious later:** this branch was written by
  > Claude in the same sitting as the plan proposing it, before Daniele had agreed
  > the item, and after he said "I didn't mean to fix it now". It is speculative
  > work parked rather than reviewed work waiting. Treat the green suite as
  > evidence the change is *self-consistent*, not that it is *wanted* — the author
  > and the reviewer were the same party, which is the arrangement that let the
  > generator ship without `mode` and the first version of
  > `docs_turn_body_contract_spec` pass vacuously.

  After the rename the pair reads correctly and neither name collides with
  `getDecision`'s meaning:

  | Ours | Does | Upstream |
  |---|---|---|
  | `await_decision(slot_id)` | the ladder | `getDecision` |
  | `poll_decision(slot_id, wait_ms:)` | one request | `pollDecisionOnce` (private) |

- [ ] **Do not make it private.** It wraps `GET /v1/decisions/{slot_id}` 1:1, and
  wrapping documented canonical endpoints is exactly what justifies
  `project_config`, `record_consent` and `activate_browser`. Removing it would be
  inconsistent with the rest of the surface, and a host driving its own polling
  loop has a legitimate use for it.
- [ ] YARD on both: say plainly that this is **not** the `getDecision` equivalent
  and point at `await_decision`. The comment is the part that stops the mistake
  recurring; the rename only stops it happening silently.
- [ ] Decision entry — it is a public API change, even pre-publication.

**Open before that branch can merge:**

- [ ] **The name.** `poll_decision` is the branch's choice. `decision_once` and
  `poll_decision_once` both say "one" more loudly; `poll_decision` reads better
  next to `await_decision`. Pick deliberately — this is the last cheap moment.
- [ ] **Whether it stays public at all.** Keeping it is the recommendation above,
  but it is a real question and the branch assumes the answer.
- [ ] **CHANGELOG.** Untouched on the branch.
- **`activate_browser`** — for the Script Tag / pure-browser path, which this gem
  does not otherwise serve. Is any host of *this gem* going to call it? If not,
  it is surface with no user.
- **`project_config`** — read-only diagnostics. Cheap to keep, easy to justify.
- **`record_consent`** — has a real use (a host with its own CMP), and the
  per-request `consent:` covers most cases without it.

**The framing that makes this feel less strange:** we are not a port of the
*SDK's surface*, we are a port of the *canonical API contract*, with the SDK as
the behavioural reference. `docs/parity.md` says this in its header. Under that
framing, wrapping a documented endpoint the SDK skipped is expected, and the only
genuine anomaly is `decision`.

**The rest of the surface stays.** Under the "canonical contract, not SDK
surface" framing it is coherent: wrapping a documented endpoint the SDK skipped
is expected, not a divergence.

- [ ] Audit `activate_browser` for a plausible caller. It serves the Script Tag /
  pure-browser path, which this gem does not otherwise support. If no host of
  *this* gem would call it, it is surface with no user — keep or drop on that
  basis, not on parity.
- [ ] Put the framing in the **README's** API section. It currently lives only in
  `docs/parity.md`, which most users never open, so the surface looks arbitrary
  at exactly the moment a reader meets it.

---

## ✅ F. A redaction hook, without monkey-patching — **BUILD**

**Daniele's shape (2026-08-11):** *"there should be a method we call passing just
the data that can be modified. If the code sets that method — like data_redactor
— fine, otherwise it just goes through."*

That is a better design than a general before-send hook, and for a specific
reason: **passing only the modifiable subset means the hook cannot rewrite what
it must not touch.** A hook handed the whole request body could change
`client_id`, drop `consent`, or inject the response-only fields the gem refuses
to send. Handed only the redactable values, it structurally cannot.

**Today.** There is no such seam. `config` exposes only inputs — `secret_key`,
`client_id`, `publishable_key`, `default_slot_hint`, `default_overrides`,
`default_publisher`, `default_consent`, `on_error`, `logger`, `wrapper_version`,
`async_queue_name`. Nothing transforms an outbound request.

The README's `data_redactor` recipe says "redact at the call site". That works
for a host calling the client directly, and **does not work for the engine
endpoint**, where the caller is `SponsorSlotsController` inside the gem. A host
wanting redaction there has no call site — only monkey-patching, which is what
this item exists to avoid.

**Scope check, so this does not get over-built.** The egress surface is small by
design: the client has *no parameter that accepts user text*. `topic:` takes a
coarse hint (#019); `slot_hint` carries layout numbers; `overrides`/`consent` are
server-configured. So this is defence in depth, and a compliance seam for hosts
who must be able to say "nothing leaves unfiltered" — not a plug for a known
leak.

- [ ] **`config.redactor`** (name TBD — `sanitize_outbound`, `before_send` are
  alternatives), a callable receiving **only the free-text values** the gem is
  about to send, returning replacements. In practice today that is `topic:`, and
  whatever future field accepts caller text.

  ```ruby
  Wavebird.configure do |c|
    c.redactor = ->(text) { DataRedactor.redact(text) }
  end
  ```

  Unset (the default) means the value goes through untouched — no branch a host
  has to opt out of, no behaviour change for anyone who ignores it.

- [ ] **Decide the granularity.** Two shapes, and it is worth choosing
  deliberately:
  - *Per-value* — `redactor.call(topic)` returns a `String`. Dead simple, and a
    host can wire `DataRedactor.redact` directly with no adapter. Cannot express
    "drop this field entirely".
  - *Per-field* — `redactor.call(:topic, value)`. Lets one hook treat fields
    differently, at the cost of every host writing a `case`.

  **Recommendation: per-value.** It is the shape Daniele described, it matches
  `data_redactor`'s own signature, and field-awareness can be added later without
  breaking it.

- [ ] **It must run inside the fail-silent boundary.** A redactor that raises
  must not take down a chat turn — same posture as `on_error` observers, which
  are already swallowed.

  **Decided (Daniele, 2026-08-11): drop the field.** A broken redactor must never
  leak the value it was installed to catch, so this fails closed. The cost is
  accepted and is worth naming: a typo in a redactor silently degrades every
  auction — `topic:` vanishes, fills get worse, and nothing errors. Mitigate by
  logging at `warn` on every raise (not once — a persistently broken redactor
  should stay noisy) and reporting through `on_error`, so the degradation is
  visible rather than merely survivable.

- [ ] **It must run after defaults merge**, or a host cannot see what is actually
  going out.

- [ ] **Specs:** the redacted value is what reaches the wire (WebMock body
  assertion, not just a unit call); a raising redactor is swallowed and behaves
  per the decision above; an unset redactor changes nothing; the redactor is
  never handed credentials or `client_id`.

- [ ] **Then rewrite the README recipe**, which currently only covers the direct
  client and silently does not apply to the engine endpoint.

**Reverses:** nothing. New surface beyond upstream — upstream has no equivalent —
so it needs a decision entry as an addition.

## ✅ G. Test the examples — **BUILD.** Highest value per effort

**Today.** `spec/wavebird/examples_spec.rb` covers **only**
`examples/chat_with_sponsored_slot/` — the non-runnable fragments. It checks they
parse, use real config options, call real helpers, and pass real keywords.

**The two runnable examples are not covered at all.** `chat_plain.rb` and
`chat_hotwire.rb` have been verified by hand — booted, curled, checked for the
slot and the async stream — and by nothing repeatable. They are the first thing a
new user runs, and they are the least tested code in the repo.

**What a spec should assert**, cheapest first:

1. **They parse** — `RubyVM::InstructionSequence.compile`, same as the fragments
   spec already does. Catches the class of error that cost a debugging round
   during authoring.
2. **The ERB templates compile** — the heredoc-quoting bug (`<%#{...}` parsing as
   interpolation) produced a *valid Ruby file* with a broken template, so parsing
   is not enough. Compile `TEMPLATE` with `ERB.new(...).src`.
3. **They boot and serve** — spawn on a free port, `GET /` expecting 200 with the
   slot markup, `POST /wavebird/sponsor_slot` expecting `{"fill": false}` with no
   key. This is the assertion that would have caught every bug found by hand.
   Slow (~20s each), so it belongs with the system specs, not the unit suite.
4. **The Hotwire one emits a session-scoped stream** — `data-wavebird-mode-value`
   present and a `turbo-cable-stream-source` whose name is not position-only.
   That is #015's property, currently proven only by a hand-run curl.

**Watch out for:** the examples load the gem via `$LOAD_PATH.unshift`, and the
system suite already sets `WAVEBIRD_SYSTEM_SPECS`/`WAVEBIRD_SKIP_COVERAGE_GATE`
because only one Rails app can exist per process. A spec that *boots* an example
must shell out to a subprocess, not `require` it.

**Recommendation:** do 1 and 2 in the unit suite immediately — they are minutes
of work and catch the two bugs that actually happened. Do 3 and 4 in the system
suite. This is the highest value-per-effort item in this plan.

---

## Suggested order

Only the ✅ items are work. The ❌ items still need **recording** — closing a
question is cheap and stops it being reopened from the wrong premise.

1. **A + B record** ❌ — two decision entries, two doc edits, no code. First
   because #004 currently reads as "possible, just deferred", which invites
   someone to attempt something structurally impossible.
2. **G (1–2)** ✅ — parse + ERB-compile specs. Minutes; catches the two bugs that
   actually happened while writing the examples.
3. **E — the rename** ✅ — the only item that gets harder after publication.
   Branch `rename-poll-decision` (`4aff31a`) exists but is unreviewed.
4. **G (3–4)** ✅ — boot-and-serve system specs for both examples.
5. **F** ✅ — the redactor seam, failing closed.
6. **D (1–2)** ✅ — React hook recipe + `examples/chat_react.rb`.
7. **C** ❌ — only if a host asks.

**Nothing here blocks a release.** If the choice is between shipping and this
plan, ship — but do step 3 first.

## How to work this plan

**Answer before you build.** Two items (A, B) dissolved entirely once the source
was actually read, and both had plausible-sounding designs sketched against them
first. Item C's real obstacle is thread safety in a long-lived Rails singleton,
which is invisible until you look at where the client lives. The pattern holds:
the expensive part of this codebase has consistently been the question, not the
code.

**Deviations need a decision entry first, not after.** WAY_OF_WORK rule 4, and
`docs/DECISIONS.md` is why a reader can tell #021's deliberate looseness from an
oversight. Items D3, F and E all add or change public surface.

**Verify against `upstream/wavebird/src/`, never against memory or the build
prompt.** Every finding in this plan came from reading the source; two of them
contradicted what the docs in this repo said. Where the source cannot answer —
`completed` in the beacon enum, whether wavebird validates `click_url` — record
that it cannot, rather than picking the comfortable reading.

**Run the example, not just the suite.** #017 survived 369 unit and 18 system
specs and died in ninety seconds against a real browser. Item G exists because
the two runnable examples are still in that gap: verified by hand once, by
nothing repeatable.

**Definition of done, per item:** gate green (`bundle exec rake` exits 0, 100%
line + branch, RuboCop clean, YARD 100%), docs updated in every place the fact
appears — not just the nearest one — and a decision entry where the surface
changed. The `mode` field went missing from the generator because "every place"
was read as "the three files I was already editing".
