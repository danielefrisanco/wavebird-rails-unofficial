# Build prompt: `wavebird-rails` — a Ruby/Rails gem for the wavebird API

Paste this whole document into a fresh session with a coding agent (Claude Code, etc.)
to generate the gem. It contains everything needed: what wavebird is, the exact API
contract, the architecture decision (Rails backend + Hotwire frontend), and the
deliverable spec (code + tests + docs).

---

## 1. Context: what wavebird is

wavebird (https://wavebird.ai) is "Compute Sponsoring" ad infrastructure for AI
products — it lets chat apps, copilots, and agents show contextual sponsored
placements (banner / native / clip) alongside AI-generated responses, without
sending prompts, chat history, or user PII to the ad network by default.

Reference links (all public):
- Marketing site: https://wavebird.ai
- Official npm/TS SDK (the thing we are reimplementing for Rails): https://www.npmjs.com/package/wavebird
- Official SDK source: https://github.com/wavebird-ai/wavebird
- Full API docs root: https://wavebird.ai/api
- API v1 reference index: https://wavebird.ai/api/v1
- LLM-oriented integration brief (very useful, read this first): https://wavebird.ai/wavebird-api-llm-integration.md
- Server API guide (recommended integration path): https://wavebird.ai/api/patterns/server-api
- Script Tag guide (browser-only alternative, not our target): https://wavebird.ai/api/patterns/script-tag
- Error codes: https://wavebird.ai/api/reference/errors
- Rate limits: https://wavebird.ai/api/reference/rate-limits
- Types reference: https://wavebird.ai/api/reference/types
- Consent in GenAI apps guide: https://wavebird.ai/api/guides/consent-genai
- Privacy: https://wavebird.ai/api/privacy · Brand safety: https://wavebird.ai/api/brand-safety
- Going live / production checklist: https://wavebird.ai/api/guides/going-live

The npm SDK is TypeScript, dual-target (Node server client + browser renderer +
React components + consent dialog), published under MIT license, maintainer
`mario.vonbassen@wavebird.ai`, ~13 weekly downloads, 6 GitHub stars (early-stage
project — a well-executed alternative SDK is genuinely useful to them, not
just a portfolio piece).

## 2. Why Rails + Hotwire, and what NOT to port 1:1

The npm package bundles two unrelated concerns that must be split, not translated
line-for-line:

| npm SDK piece | Ruby equivalent | Notes |
|---|---|---|
| `src/index.ts` (`WavebirdClient`, job/decision calls) | Ruby API client class | Pure HTTP, fully portable |
| `src/public_contracts.ts` (request/response types) | Ruby value objects (`Wavebird::Placement`, `Wavebird::Decision`, etc.) | Port field-for-field from docs, not from guessing |
| `src/components/WavebirdAd.tsx` (React renderer) | **Do not port.** Use the hosted renderer (`/v1/render.js` + `frame_url`) via a Turbo Frame instead | wavebird already serves a hosted iframe/script renderer; Rails doesn't need to reimplement creative rendering |
| `src/components/beacon-tracker.ts` (view/click tracking) | Prefer wavebird's hosted renderer beacons (automatic). Only implement direct `/v1/beacons` calls for a server-rendered/custom fallback path | See §5 |
| `src/consent/ConsentDialog.tsx` | Not needed for v1 — expose `Wavebird.consent!` as a plain API call; a Rails app's existing CMP/consent UI feeds it | |

**Architecture decision:** the gem is a **server-side API client + Rails
integration glue** (routes, a controller concern, a Turbo Frame helper, a
Stimulus controller for the hosted renderer's turn lifecycle). It does **not**
reimplement ad rendering — it wires the Rails app up to wavebird's own hosted
renderer (`GET /v1/render.js`, `GET /v1/render/{asset_token}`), which is the
officially recommended "Server API" pattern (see the LLM integration brief,
section "Recommended architecture"). This is also strictly safer: it keeps
`WAVEBIRD_SECRET_KEY` server-side only, per wavebird's own privacy rules.

## 3. Full API surface to implement (base URL `https://api.wavebird.ai`, version `v1`)

Auth: `Authorization: Bearer <key>`. Credential classes (never mix): Server Test
Key (`sk_test_...`, sandbox, non-billable), Server Production Dry-run Key
(`sk_dry_...`, non-billable, no payout setup needed), Server Production Key
(`sk_live_...`), Browser Publishable Key (`pk_...`, browser-only, never used
server-side). Do not send `production_dry_run`, `production_billing_dry_run`,
`billing_suppressed`, or `production_live_approved` in request bodies — those
are response/diagnostic-only fields, dry-run mode is selected purely by which
key class you use.

### 3.1 `POST /v1/placements` (primary endpoint — creates a job and waits for the first decision)
Query: `?wait_ms=1500` (recommended).
Request body:
```json
{
  "client_id": "wbproj_...",
  "session_id": "sess_...",
  "job_type": "chat",
  "slots_requested": 1,
  "slot_hint": { "position": "below", "max_width": 728, "max_height": 90 },
  "overrides": { "allowed_formats": ["banner", "clip", "native"], "timing": "during" },
  "consent": {
    "semantic_targeting": false,
    "prompt_shared": false,
    "gdpr_applies": false,
    "consent_source": "wavebird_consent"
  }
}
```
Response: `slot_id`, `status`, `placement` (may be `null` on no-fill; contains
`format`, `width`, `height`, `ad_label_text`, `sponsor_name`, `click_url`,
`asset_token`, and a `render` object with `strategy: "hosted_frame"`,
`frame_url`, `script_url`), `decision` (`fill: boolean`, `format`,
`asset_token`, `assets` for native creatives). **If `placement` is null or
`decision.fill` is false, the caller must hide the ad slot and continue
normally — this must be a first-class case in the gem, not an error.**

### 3.2 `POST /v1/jobs` — advanced/compatibility route, creates a job and returns one or more `slot_id`s without waiting. Implement for parity but document `/v1/placements` as the recommended default.

### 3.3 `GET /v1/decisions/{slot_id}` — polls a slot for its decision (used with `/v1/jobs`, or to re-poll after a `/v1/placements` timeout).

### 3.4 `POST /v1/browser/activate` — exchanges a publishable key + `Origin` header for a short-lived browser activation token. Needed only if the gem later supports the Script Tag / pure-browser pattern; implement but mark as secondary.

### 3.5 `GET /v1/render.js` and `GET /v1/render/{asset_token}` — these are not called directly by Ruby; they are loaded by the browser via the Turbo Frame `src`/`frame_url`. The gem must expose helpers that emit the right `<script src="...">` tag once and a Turbo Frame per slot pointing at `frame_url`.

### 3.6 `POST /v1/beacons` — advanced/direct path. Full field table:

| Field | Required | Notes |
|---|---|---|
| `beacon_id` | yes | idempotency key |
| `slot_id` | yes | |
| `asset_token` | yes | **sensitive** — from `placement.asset_token`/`decision.asset_token`; never log, never expose to frontend beyond what hosted renderer needs |
| `event` | yes | one of `rendered`, `visible`, `clicked`, `completed`, `play_started`, `play_completed`, `heartbeat` |
| `occurred_at` | yes | **must be a freshly generated ISO8601 timestamp at call time** — stale/copied timestamps return `BEACON_TOO_LATE` |
| `metadata` | no | free-form object |

Response includes `ok`, `accepted`, `duplicate`, `reason_code`, plus diagnostic
fields (`proof_source`, `proof_eligible`, `billable`, `geometry_reason`, etc. —
model these but the gem should treat unknown fields tolerantly since this is a
diagnostics-heavy endpoint that may grow fields).

**Default posture: prefer the hosted renderer, which sends these beacons
automatically to `/public/wrapper/v1/beacons` — the gem should not duplicate
that. Only implement `Wavebird::Client#record_beacon` as an escape hatch for
custom/server-rendered flows, clearly documented as advanced/optional.**

### 3.7 `POST /v1/consent` — optional session/user-level consent sync (distinct from the per-request `consent` object inside `/v1/placements`, which is NOT dependent on this call). Body:
```json
{
  "client_id": "wbproj_...",
  "session_id": "sess_...",
  "decision": "custom",
  "source": "publisher_custom",
  "purposes": {
    "semantic_targeting": false,
    "session_persistence": true,
    "cross_session_persistence": false,
    "prompt_shared": false
  }
}
```
`decision` ∈ `personalized|basic|custom`. `source` ∈ `publisher_custom|server_sync|wavebird_dialog` (aliases `publisher`, `custom_dialog` map to `publisher_custom` — support them but don't emit them).

### 3.8 `GET /v1/projects/{client_id}/config` — non-secret runtime project config.

### 3.9 Error envelope (applies to all endpoints)
JSON body: `{ "error": "<code>", "message": "...", "docs_url": "...", "request_id": "..." }`, also echoed in `X-Request-Id` header. Lowercase codes: `unauthorized` (401), `forbidden` (403), `rate_limited` (429, honor `Retry-After`), `validation_error` (400, includes field paths), `not_found` (404). The gem must raise a distinct Ruby exception per code (`Wavebird::UnauthorizedError`, `Wavebird::ForbiddenError`, `Wavebird::RateLimitedError`, `Wavebird::ValidationError`, `Wavebird::NotFoundError`), all subclassing `Wavebird::Error`, and must expose `request_id` on every raised error for support/debugging.

## 4. Privacy/product rules the gem must enforce or make impossible to violate

Straight from wavebird's own integration brief — bake these in as defaults, not just docs:
- Never accept or forward prompts, full chat history, user IDs, emails, or account data in the placement request by default — the client's public API should not even have a parameter that invites this by accident.
- `WAVEBIRD_SECRET_KEY` must never be reachable from asset pipeline/browser bundles — the gem's Railtie should fail loudly (raise at boot, not silently no-op) if someone requires the client from `app/javascript` or similar.
- On any error or no-fill, the host app's AI response path must be unaffected — model this as `Wavebird::Client` never raising for a no-fill (`decision.fill == false` is a normal, successful response), only raising for actual HTTP/API errors.
- `asset_token` is sensitive proof material: must be redacted from any gem-provided logging/instrumentation.

## 5. Gem architecture to generate

Gem name: **`wavebird-rails`** (module `Wavebird`, engine `Wavebird::Engine < ::Rails::Engine`).

```
wavebird-rails/
  lib/wavebird/
    client.rb              # Faraday-based HTTP client: #create_placement, #create_job,
                            #   #decision(slot_id), #activate_browser, #record_consent,
                            #   #record_beacon, #project_config
    configuration.rb        # secret_key, client_id, api_base_url (default https://api.wavebird.ai),
                            #   default slot_hint/overrides, request timeout, logger
    errors.rb                # Wavebird::Error hierarchy per §3.9
    types.rb                  # Placement, Decision, Render, ConsentState — plain Ruby Struct/Data value objects
                              #   mirroring public_contracts.ts field names exactly
    railtie.rb                 # boot-time check that secret key isn't in an asset-pipeline-reachable initializer
    engine.rb
  app/
    controllers/wavebird/sponsor_slots_controller.rb   # POST — mirrors the Next.js/Express example route:
                                                        #   calls Client#create_placement server-side,
                                                        #   returns JSON to the Turbo Frame/Stimulus controller
    helpers/wavebird/slot_helper.rb                     # wavebird_render_script_tag, wavebird_slot(session_id:, **opts)
                                                        #   -> renders <turbo-frame id="wavebird-slot-..." src="...">
    javascript/controllers/wavebird_controller.js       # Stimulus controller wrapping window.wavebird.withTurn(),
                                                        #   loads /v1/render.js once, hides frame on no-fill
  config/routes.rb            # mounts POST /wavebird/sponsor_slot
  spec/ or test/              # see §6
  README.md, CHANGELOG.md, LICENSE (MIT, matching upstream)
```

Public Ruby API sketch:
```ruby
Wavebird.configure do |c|
  c.secret_key = ENV.fetch("WAVEBIRD_SECRET_KEY")
  c.client_id  = ENV.fetch("WAVEBIRD_CLIENT_ID")
end

placement = Wavebird.client.create_placement(
  session_id: session[:wavebird_session_id],
  job_type: "chat",
  slot_hint: { position: "below", max_width: 728, max_height: 90 },
  overrides: { allowed_formats: %w[banner clip native], timing: "during" },
  consent: { semantic_targeting: false, prompt_shared: false, gdpr_applies: false }
)
# placement.fill? / placement.decision.fill
```

View helper usage:
```erb
<%= wavebird_render_script_tag %>
<%= wavebird_slot(session_id: session[:wavebird_session_id], endpoint: wavebird_sponsor_slot_path) %>
```
which should render markup equivalent to the plain-HTML example in the
integration brief (hidden `<section data-wavebird-endpoint>` + Stimulus
controller calling `withTurn`), just Hotwire-idiomatic (Turbo Frame instead of
manual DOM mount).

## 6. Testing requirements

- Unit tests for `Wavebird::Client` against a stubbed HTTP layer (WebMock or
  Faraday test adapter) covering: successful placement with fill, successful
  placement with `fill: false`/`placement: null`, every error code in §3.9
  mapped to its exception class, `Retry-After` handling on 429, idempotent
  beacon (`duplicate: true`), and `BEACON_TOO_LATE` validation error.
- Request/controller spec for `Wavebird::SponsorSlotsController` verifying the
  secret key is read server-side only and never included in the JSON returned
  to the browser.
- System/integration test (Capybara) simulating a chat send that triggers
  `withTurn`, mocking `/v1/placements` to fill, asserting the Turbo Frame
  renders; and a no-fill case asserting the frame stays hidden and the rest of
  the page/chat flow is unaffected.
- A Railtie boot test asserting the app raises if `secret_key` is blank at
  first client use, and that the gem never exposes secret_key via any
  helper/view/JSON payload.
- Aim for 100% coverage on `lib/wavebird/*`; use RSpec + SimpleCov.

## 7. Documentation requirements

- `README.md`: what it is, install (`bundle add wavebird-rails`), quickstart
  (mirroring the Next.js example in the integration brief but Rails-flavored),
  full public API reference table, privacy rules from §4 stated explicitly,
  link back to https://wavebird.ai/api and https://github.com/wavebird-ai/wavebird
  as the canonical source of truth.
- YARD docs on every public method.
- `CHANGELOG.md` following Keep a Changelog.
- A `examples/` directory with a minimal Rails app (or at least a controller +
  view pair) showing the chat-with-sponsored-slot pattern end to end.

## 8. Deliverable / acceptance criteria

1. `wavebird-rails` gem, MIT licensed, installable via `bundle add wavebird-rails`.
2. Passes `bundle exec rspec` with the coverage described in §6.
3. `rubocop` clean (standard Ruby style).
4. README quickstart works copy-pasted into a fresh `rails new` app against
   wavebird's sandbox (`sk_test_...` key) and successfully renders a demo
   placement per the `/v1/placements` sandbox example in §3.1.
5. No secret key ever reachable from `app/assets`, `app/javascript`, or any
   JSON response — verified by an explicit test.
6. Gemspec `homepage`/`metadata["source_code_uri"]` point at the gem's own
   repo; README explicitly credits wavebird (https://wavebird.ai) and the
   original TypeScript SDK (https://github.com/wavebird-ai/wavebird) as the
   API this wraps.

---

Note for whoever runs this prompt: the API details above were pulled directly
from wavebird's public docs on 2026-07-18. Before publishing the gem, re-check
https://wavebird.ai/api/changelog and https://wavebird.ai/api/reference/versioning
in case the contract has moved, and confirm sandbox credentials still work
against https://wavebird.ai/api/quickstart.
