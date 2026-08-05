# Devlog — wavebird-rails

Reverse chronological. Each entry: done / todo / problems found.

## 2026-08-05 — Parity re-review, and closing the fail-silent gaps (branch `parity-fail-silent`)

Daniele asked for a fresh parity review of the whole API against the original
SDK, then for the findings written down, then for the divergences fixed.

**Done**
- **`docs/parity-findings.md`** — an independent re-walk of upstream
  `src/` against the shipped gem: 13 areas confirmed at parity, the 11 recorded
  divergences restated, and 12 findings that were in neither document.
- **Documentation-only fixes (F8, F12)** — the `create_job` README row regained
  `consent:` (drift since #014); `docs/parity.md`'s "verify the server accepts
  arbitrary `wrapper_version` values" caveat was answered by the 2026-08-04
  sandbox run, which rendered a real ad with `wavebird-rails/{VERSION}` in the
  header; the `DecisionTimeoutError` comment stopped describing a pending
  fallback the facade did not produce.
- **F1–F4 fixed (decision #018)** — the fail-silent layer now covers the whole
  client surface with upstream's own fallback values: five methods gained
  non-raising forms, a 429 on `create_job` returns `Types::RateLimited` instead
  of `nil` (warn, not `on_error`, as upstream), the decision-timeout fallback is
  pending rather than a fabricated no-fill, and a failed beacon returns
  `{accepted: false, reason_code: "SDK_FAIL_SILENT"}`.
- **`SlotPayload.no_fill`** — the `{fill: false}` literal now has one home, used
  by the payload projection and by the endpoint's rate-limit path.

**Problems found**
- **`report_generation` was reachable only in its raising form.** Upstream
  documents it `@throws Never` and it is called from inside the host's
  generation loop — so the one method most likely to sit in a chat turn was the
  one that could take the turn down. The facade covered 4 of 9 methods and
  nobody had asked why the other 5 were missing.
- **We had invented three fallback values.** `nil` for a beacon, a *ready
  no-fill* for an exhausted polling budget, `nil` for a rate limit. Each looked
  reasonable in isolation; each said something upstream does not say. The
  decision-timeout one asserted a verdict the auction never delivered.
- **A rate limit was being treated as a failure.** Upstream is explicit — 429 on
  `createJob` is a typed *result* and deliberately bypasses `onError`. The
  endpoint would also have retried a throttled async job through the blocking
  path, spending the next 429 immediately.
- **Constants inside `Data.define do … end` do not scope to the class** (block
  bodies keep the enclosing lexical scope), so `RateLimited::ERROR_CODE` would
  have quietly become `Types::ERROR_CODE`. Replaced with a
  `RateLimited.from_retry_after` constructor that names the code once.

**Verification**
- Unit + request suite: 398 examples, 0 failures, 100 % line + branch.
- System suite: 18 examples, 0 failures. RuboCop clean over `lib/`, `app/`,
  `spec/`. YARD 100 % documented.

**Then, same day — F5 settled by asking the sandbox (decision #019)**
- No document states the `/v1/placements` request schema, so a probe script sent
  the gem's baseline body plus one variant per field with the `sk_test_` key.
  `locale` and `prompt: {topic:}` → 200; an unknown field at either level →
  `400 validation_error`. Those controls are the point: without them a 200 could
  have meant "ignored". `create_placement` now takes `topic:` and `locale:`.
- Fetched the hosted Script Tag (`wavebird.js`, 32 KB) while at it: it drives
  `/v1/jobs` + `/v1/decisions/{slot_id}` with the *legacy wrapper ingress* body
  (`chat_session_id`, `slot_config`, `delivery: {mode: "polling"}`) and never
  touches `/v1/placements`. So wavebird's own Script Tag runs the same
  create-job-then-poll route we ported, and it tells us nothing about the
  placements schema — the sandbox was the only way to know.
- Left out on Daniele's call: no `default_locale` config, and the endpoint still
  refuses a browser-supplied `topic` (upstream builds it from a server-side
  argument; the Script Tag's page-supplied version runs under a different trust
  model).

**Todo**
- F6 (deprecation warning for `timing: before|after`) and F7 (`hosted_frame`
  completeness validation) are scoped in the findings doc, undecided.
- Merge `parity-fail-silent` once reviewed.

## 2026-08-04 — Phase 10 close-out: first live sandbox run, and the bug it found

Daniele asked for something the plan had deferred all build long: *"a chat example
running with the ror gem using the wavebird test key, and I need to chat and see
the output of wavebird."* A real host app, a real key, a real browser. It took
about an hour and it was worth every minute — the gem had never once rendered an
ad outside its own test harness, and nothing in the suite could tell us.

**Done**
- **Chat demo against the live sandbox** — a small Rails app (scratchpad, not in
  the repo) mounting the engine, using `wavebird_slot` + the path-A turn bridge,
  with a stub "AI" that sleeps 6s so the sponsor slot is visible for a whole turn.
  Real `sk_test_` key, real `api.wavebird.ai`, real hosted `render.js`. This
  closes the acceptance §4 smoke test, open since Phase 1.
- **The payload bug fixed (#017)** — `SlotPayload` now nests the browser-safe
  fields under `placement.render`, the shape upstream actually produces, on both
  the blocking and async paths.
- **The gap that hid it closed** — `render_js_contract_spec.rb` grew from an
  entry-point check into a shape check: it pins the five snapshot source lines
  that decide whether a response paints anything, pins `frame_url` to the exact
  `placement.render` path, and — where node is available — lifts
  `placementFrom`/`renderFrom` straight out of the dated snapshot and runs
  **wavebird's own code** against the real `SlotPayload` output. One case asserts
  the old flat shape resolves to nothing. Verified by reverting the fix: three
  examples fail, including the node-executed one.
- **`spec/dummy/public/v1/render.js` rewritten** to port `placementFrom`/
  `renderFrom` verbatim instead of reading the gem's shape.
- **Phase 10.5 added to the plan** — `rails g wavebird:install` and onboarding.
  Daniele's framing: *"the gem must be usable from users easy; if it is too
  difficult to use we will have to think about it."* Installing the gem is eight
  steps against the vendor's three. That is a product problem, not a docs problem.

**Problems found**
- **The gem never rendered an ad with the real renderer. Ever.** The endpoint
  returned a flat `{fill: true, frame_url: …}`; the hosted renderer resolves a
  response through `placementFrom` → `renderFrom`, which reads only
  `p.render.frame_url` or rebuilds from `p.asset_token` (which we deliberately
  never send). A flat `frame_url` satisfies neither, so `startTurn`'s
  `if(!p||!p.render)` discarded it and the slot silently stayed empty — in every
  mode. There is **no error path** for an unresolvable payload: an unreadable
  response and an honest no-fill are the same code path, `clearPlacement`. No
  console message, no failed request, nothing. See #017.
- **The test suite was checking our assumption against itself.** The stand-in
  render.js had been written to consume *our* payload — it wrapped the flat
  object as `placement:{render:decision}` before reading `.frame_url`, so of
  course it worked. 369 unit and 18 system examples were green throughout. The
  contract spec pinned the *names* of the entry points and never the shape they
  accept, which is precisely half a contract.
- **The integration brief had told us.** It says the backend "returns the wavebird
  JSON response to the browser." We returned a reshaped one and did not notice
  that reshaping it was a decision.
- **Chromedriver fell back to a v113 driver.** Chrome auto-updated to 151 while
  the system chromedriver sat at 150; the exact-major check rejected it and fell
  through to PATH, which held a driver 38 majors stale — a worse choice, made
  confidently. Now tolerates a skew of 2 and picks the closest candidate.
- **Three self-inflicted demo boot failures**, all the same mistake: defining
  controllers and routes before `Rails.application.initialize!`, so they missed
  the engine's helper modules and the mounted-route proxy. Daniele, reasonably:
  *"why is it so difficult, I thought the gem was ready."* The gem was fine; the
  hand-rolled single-file app was not. It is an argument for Phase 10.5.
- **`bundle exec rake 2>&1 | tail` reports `tail`'s exit code.** I read a green
  exit from a piped rake twice before noticing the YARD gate was failing on an
  undocumented `SlotPayload::DEFAULT_HEIGHT` (two constants, one shared comment —
  YARD attaches it to the first). Fixed the constant; stopped reading exit codes
  through a pipe.
- **A process error worth recording.** Daniele asked a clarifying question about
  the async raise and added "I don't want to take down the page"; I treated that
  as approval and started editing. It was not approval — it was context for a
  question. *"Stop. I NEVER SAID YOU TO DO ANYTHING, I ASKED a question."* The
  rule stands and is in WAY_OF_WORK: a question is answered, then I wait.

**Verification**
- Unit + request suite: 379 examples, 0 failures, 100% line + branch.
- System suite: 18 examples, 0 failures. RuboCop clean across 57 files. YARD 100%.
- Live: a filled slot rendering in Chrome from the sandbox, cleared when the turn
  finished — the behavior the whole gem exists to produce, observed for the first
  time.

**Todo**
- `/code-review ultra` has only seen through `55563e0`; the payload fix and the
  contract spec came after.
- `gem install pkg/*.gem` into a fresh `rails new` → Phase 11.
- Phase 10.5 (install generator, no-Stimulus-first docs, runnable demo) is scoped
  but unstarted.

## 2026-08-02 (later) — Phase 10: parity + quality audits

**Done**
- **Parity table re-walked field-for-field** against the shipped gem and
  `upstream/wavebird/src/`. Confirmed at parity: config defaults/clamps,
  `parseRetryAfterMs`'s fall-through order, base-URL normalization, the canonical
  `/v1/jobs` body, beacon 204 handling, the polling ladder, all five enums. Four
  deliberate divergences now recorded explicitly in `docs/parity.md` (no
  `prompt.text` parameter by design, free-form `overrides`, raising on non-finite
  numeric config, no `asset_token → slot_id` memo).
- **Changelog re-checked live** (`wavebird.ai/api/changelog`): still "2026 Q2",
  byte-identical to the Phase 0 snapshot. No contract drift.
- **Consent posture settled (#013).** The integration brief's reference backend
  hard-codes `semantic_targeting: false, prompt_shared: false, consent_source:
  "wavebird_consent"`; the gem sends nothing unless the caller does. Checked the
  SDK rather than the brief — it injects no defaults either, and that
  `consent_source` value appears only in deprecated DOM components after a real
  dialog decision. Daniele's call: match the SDK. Documented in the README, with
  the note that a host's own CMP is `publisher_custom`, not `wavebird_consent`.
- **Async no longer drops consent (#014a).** `#create_job` gained `consent:` and
  folds `gdpr_applies` into `overrides.gdpr_applies` per upstream
  `createV1JobRequest`; other flags are named in a warning instead of vanishing.
  The controller stopped stripping consent from `job_args`.
- **CI matrix rebuilt (#014b)** as `gemfiles/rails_{7.1,7.2,8.0,8.1}.gemfile`,
  each setting `RAILS_VERSION` and `eval_gemfile`-ing the root Gemfile. Closes
  the Phase 1 checkbox that had been open since the start.
- Gem hygiene verified: 31 files packaged, no test files, MFA required, semver,
  MIT, minimal runtime deps.

**Problems found**
- **The CI matrix was silently broken, and CI had never run** (no git remote, `gh`
  unauthenticated). Nothing capped Rails, so all three Ruby legs resolved railties
  8.1.3. Verified locally: Ruby 3.2.2 green, **3.3.0 hard `SyntaxError`**
  (`actionview-8.1.3/capture_helper.rb:50: anonymous rest parameter is also used
  within block`), 3.4.10 green — the check landed in Ruby 3.3 and was relaxed
  again in 3.4. This refines #007, which claimed 8.1.3 cannot parse on 3.3: true
  for 3.3, but 3.2 parses it fine. After the fix, 3.3/7.1, 3.2/8.0 and 3.4/8.1 all
  run 350 examples green.
- **I overstated the consent finding** before checking the SDK, calling it a
  build-prompt §4 requirement. §4's four rules are no prompts/PII forwarded, key
  not browser-reachable, no-fill leaves the host flow intact, `asset_token`
  redacted — consent defaults are not among them. Corrected in #013.
- Running the matrix with `BUNDLE_PATH` pointed at a scratchpad rewrote the root
  `Gemfile.lock` to gems installed only there; deleting the scratchpad broke the
  local bundle until `bundle install` restored it. The per-Rails gemfiles avoid
  this — each keeps its own lockfile and shares the default gem path.

**Security review (manual — the skill needs `origin/HEAD` and there is no remote)**

Three findings, all fixed under decision #015:

1. **High — async broadcast every user's placement to every user.** The Turbo
   Stream was named `wavebird_slot_{position}` on both ends, so all visitors at a
   position shared one channel: one visitor's decision, `frame_url` and embedded
   `asset_token` included, reached every other subscriber, mounting their ad and
   firing their beacons from unrelated browsers. Fixed by scoping the name to the
   session in one shared place (`SlotPayload.stream_name`) — which is also what
   upstream does, since its decision transport is a *per-slot* WebSocket.
2. **Medium — the broadcast target came from the client.** `stream_name` was read
   from params and passed to `broadcast_append_to`; Turbo signs stream names when
   subscribing but not when broadcasting. It is no longer a param, a Stimulus
   value, or part of the request body; the job takes `position` explicitly.
3. **Medium — browser-supplied `overrides`/`consent` beat server config.** A page
   could clear `blocked_categories`, zero a `bidfloor`, or claim
   `semantic_targeting: true`. Both dropped from permitted params; `overrides`
   now comes from config and consent from the new `config.default_consent`
   (still `nil` by default, so #013 stands).

Clean: secret-key handling (read only in `require_secret_key`, only ever the
`Authorization` header, redacted in `inspect`, absent from instrumentation), the
broadcast partial (escapes, no `raw`, no inline `<script>`).

**Correction, same day (#016):** the first cut had the view helper *raise* when
`async: true` came without a `session_id`. Daniele pushed back — a raise inside
`wavebird_slot` 500s the host's chat page, which is the one outcome the gem
promises the ad path will never cause. He was right, and it was inconsistent
too: the endpoint already warns and falls back for a missing Turbo/ActiveJob
(#010). Checked upstream before changing rather than after: the SDK's callback
mode throws `sdk_missing_callback_url`, but inside `createJob`'s own `try`, so
the caller gets a reported error and `null` — `@throws Never`. Reported-and-
degraded is upstream's posture; raising was mine. The helper now warns and
renders a blocking slot. The security property is untouched, since it comes from
the stream being scoped, and blocking mode has no stream at all.

**The regression test was verified against the vulnerable code.** With the
session scoping reverted, the new two-session spec fails on all four assertions —
including visitor B's page containing visitor A's `at_secret_async` token. That
is the leak, reproduced, and it is why a single-session suite never saw it.

**Ultrareview (cloud, 27 files / ~724 insertions)** — one finding, classified
pre-existing: `create_job` did not fall back to `config.default_slot_hint` while
`create_placement` did, and the browser never sends a `slot_hint`, so a host's
configured hint reached the auction in blocking mode and vanished in async. Same
class of gap as the consent one fixed in #014a, one line away in the same method,
and missed while fixing that one. Fixed by mirroring `create_placement`; spec
verified against the unfixed code. Nothing flagged on the security work.

Worth noting the review did *not* surface the raise-vs-degrade problem — no
crash, no wrong output, working as written — which Daniele caught by asking why.
The more consequential of the two came from the human read.

**Todo**
- `gem install pkg/*.gem` into a fresh `rails new` app → Phase 11.
- Sandbox smoke test still blocked on `sk_test_...` credentials.

## 2026-08-02 — Phase 9: documentation & examples

**Done**
- README rewritten as the gem's front door: what/why (the three design
  commitments), install, a three-file quickstart mirroring the brief's Next.js
  example, full public API tables (module, facade, client, Rails integration,
  configuration, errors), the credential-class table, the §4 privacy rules
  restated as enforced behavior, and credits.
- YARD at **100%** (`yard stats --list-undoc` clean). `.yardopts` hides
  `@api private` internals; the remaining gaps were real — polling constants,
  creative defaults, `VERSION`, `RENDER_PATH`, `DEFAULT_API_BASE_URL` — and are
  now documented individually. New `rake yard_coverage` task guards it and joins
  the default task.
- `examples/chat_with_sponsored_slot/` — initializer, routes, both controllers
  and the view, laid out as a host-app tree with a README explaining the flow and
  why it is safe to try without a key (an unconfigured key is just a no-fill).
- `CHANGELOG.md` 0.1.0 entry covering the whole surface built in Phases 0–8.
- `spec/wavebird/examples_spec.rb` (10 examples): the example files parse, set
  only real `Configuration` options, call only real `SlotHelper` helpers with
  keywords `wavebird_slot` accepts, include the concern *and* the helper opt-in,
  and mount the engine the view's route helper assumes.

**Problems found**
- **A real documentation gap, caught by writing the example.** The engine is
  namespace-isolated, so its view helpers are not mixed into host views
  automatically — a host must `helper Wavebird::SlotHelper`. `spec/dummy` did
  exactly that (with a comment claiming INSTALL.md documented it), but no
  user-facing doc mentioned it. A copy-pasted quickstart would have died on
  `undefined method wavebird_slot` — i.e. acceptance §4 would have failed on a
  real user's first attempt. Now in README, INSTALL.md and the example, and
  asserted by the examples spec.
- `Style/HashSlice` fired on `Method#parameters.select` in the new spec; its
  autocorrect would have been wrong (that's an Array, not a Hash). Rewritten as
  `filter_map`.

**Todo**
- Phase 10: parity audit vs the TS SDK, `/code-review` + `/security-review`, gem
  hygiene (`spec.files`, `rake build`, install into a fresh `rails new`), and the
  sandbox smoke test once credentials exist.
- Still open from Phase 1: the CI matrix lists Ruby 3.2/3.3/3.4 but Rails 8.1
  needs 3.4 (decision #007) — reconcile in Phase 10.
- Deferred: system-suite speedup (browser reuse; ~4 min for 17 examples today).

## 2026-08-01 — Phase 8: dummy host app + Capybara system tests

**Done**
- `spec/dummy` — a real Rails host app (routes, session store, Turbo Streams over
  ActionCable) driven through headless Chrome, so the browser glue from Phases
  6a/6b is exercised rather than simulated.
- **No JS build step.** An importmap serves ES modules straight from where they
  live — the gem's own `app/javascript` and the stimulus/turbo gems, via a small
  `JsServer` — so nothing is vendored, copied or symlinked, CI needs only Ruby +
  Chrome, and the specs load the exact files the gem ships. (First attempts used
  copies, then symlinks; both were wrong — copies drift, symlinks embed absolute
  machine paths.)
- `spec/dummy/public/v1/render.js` — a stand-in for the hosted renderer, which
  cannot be fetched with net connections disabled. `render_js_contract_spec.rb`
  pins both it and the dated upstream snapshot against the entry points the gem
  drives, so refreshing the snapshot fails loudly rather than silently
  invalidating every system test.
- 17 system examples, all green: 12 blocking (paths A and C across fill, no-fill,
  API down, renderer absent, session-id propagation, secret-key exclusion) and 5
  async (endpoint answers `{pending: true}`, job polls, *real* cable broadcast,
  Stimulus reveal, token boundary).
- CI gains a `system` job (Ruby 3.4 + Chrome) running `rake spec:system`.

**Two bugs the browser found — neither visible to unit tests (decision #012)**
1. **Async mode was unreachable from the browser.** The helper rendered the Turbo
   Stream subscription, but nothing told the endpoint to use async: the Stimulus
   controller never sent `mode`/`stream_name`, so every async slot silently fell
   back to blocking. A host following INSTALL.md would have got the wrong
   behavior with no error. Fixed on both sides.
2. **The broadcast never reached the DOM.** The job used `broadcast_replace_to`
   with `target:` set to the *stream* name (`wavebird_slot_below`), which no
   element on the page had — and a Turbo Stream `replace` against a missing
   target is a silent no-op, so the message arrived and did nothing. Fixed:
   `broadcast_append_to` into the slot `<section>` itself, with
   `SlotPayload.slot_dom_id` now the single source of that id for helper and job
   alike, and the Stimulus handler removing the signal node once consumed.

**Notes**
- Only one Rails application can exist per process, so the system specs run as
  their own process (`rake spec:system`, excluded from bare `rspec` via `.rspec`)
  while the rack-test app keeps serving the request specs. Coverage is written to
  separate directories and the 100% gate applies to the unit run only.
- One assertion of mine overreached and had to be corrected rather than the code:
  "the asset token never appears in the browser" is false by design — it is
  embedded in `frame_url`, which is how the hosted renderer authenticates the
  frame (decision #009). The spec now asserts what the blocking path asserts: no
  bare `asset_token` field, and the token present only inside the frame URL.

**Verification**
- Unit + request suite: 333 examples, 100% line + branch, RuboCop clean.
- System suite: 17 examples, 0 failures. It is slow — Chrome launches per example
  — so it is deliberately kept out of the default `rspec` run.

## 2026-07-31 — Phase 7: Railtie security checks (boot guards + leak audit)

**Done**
- `Wavebird::BootCheck` — two independent boot-time guards (decision #011), both
  raising `ConfigurationError` loudly per build prompt §4:
  - `assert_server_side_require!` runs at `require "wavebird"` time and rejects a
    require whose first non-gem, non-Ruby-internal caller frame lives under a
    host's `app/assets` / `app/javascript`. Message names the offending file and
    says where to require it instead.
  - `assert_assets_paths_safe!` rejects asset load paths that would publish the
    gem's server-side Ruby (gem root, its `lib/`, or an ancestor containing it),
    while allowing the gem's own `app/javascript` — the documented importmap path,
    which holds only Stimulus glue.
- `Wavebird::Railtie` with the `wavebird.boot_check` initializer running the
  asset-path scan. Separate from `Engine` (which already subclasses `Railtie`) so
  the guard runs whether or not the engine is mounted, matching the build prompt's
  file layout. Required from `lib/wavebird-rails.rb`'s Rails-present branch.
- `spec/wavebird/leak_audit_spec.rb` — the plan's grep-based source audit: scans
  every `lib`/`app` Ruby file for interpolation of `secret_key`/`asset_token`, with
  a three-entry allowlist each carrying its rationale (the `Bearer` header;
  `slot_payload`'s server-side `frame_url`; `configuration`'s redacting `#inspect`).
  It caught the `configuration.rb` inspect line on first run — reviewed, confirmed
  safe (emits only `nil`/`[REDACTED]`), allowlisted.

**Notes**
- Four of Phase 7's nominal requirements were already satisfied and specced before
  this phase (blank-key raise at first client use, `secret_key` out of `#inspect`,
  `asset_token` scrubbed from instrumentation and value-object output); this phase
  re-confirmed them and built the two genuinely missing pieces.
- The raising path is unit-tested with injected caller frames / asset paths rather
  than by booting a doomed app: the harness boots one in-memory `Rails::Application`
  per process and cannot boot a second. Its successful boot exercises the passing
  path for real. A subprocess boot-raise test can come with Phase 8's `spec/dummy`.
- §4 says "raise at boot" while §6's test bullet says the blank-key raise happens
  "at first client use" — different checks, both honored: the blank-key raise stays
  lazy in `require_secret_key`; these guards are about *reachability*.

**Verification**
- Smoke-tested the guard end-to-end outside the suite: a `require "wavebird"` from
  a fake `app/javascript/` file raises with the actionable message; the same
  require from `app/models/` loads clean.
- `rake` green on Ruby 3.4.10: 319 examples, 100% line + branch, RuboCop clean.

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
