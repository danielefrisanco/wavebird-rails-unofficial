<!-- Snapshot of https://wavebird.ai/api/reference/types taken 2026-07-18; extracted from HTML, formatting approximate. -->

Search API docs/

# Type and runtime reference

This page collects the public runtime shapes that matter most for API-first integration. It focuses on Script Tag because that is the primary browser entrypoint now.

## Key classes

Server Test Key (sk_test_...)

Backend-only credential for Test/Sandbox requests. Test/Sandbox traffic, validation diagnostics, render signals, and proof signals are non-billable.

Server Production Dry-run Key (sk_dry_...)

Backend-only credential for non-billable pre-live dry-run. Production dry-run is selected by credential class, not by request fields.

Server Production Key

Backend-only credential for approved live traffic after Dashboard live readiness, SSP readiness, payout requirements, and live approval gates are complete.

Browser Publishable Key

Browser credential for Script Tag or activation flows with allowed origins. Browser Publishable Keys are separate from server secrets and cannot be used for server endpoints.

One-time server secret visibility

Raw server secrets are shown only once after create or rotate. Existing masked server-secret previews identify a key but are not usable credentials. Do not send production_dry_run, production_billing_dry_run, billing_suppressed, or production_live_approved in request bodies.

## Script Tag attributes

data-client-id

Required. Public client identifier for the app whose server-side config should load.

data-publishable-key

Required in production. Browser-safe pk_publishable_* key bound to your allowed origins.

data-session-id

Optional stable session identifier for consent, pacing, and future frequency controls.

data-job-type

Optional product hint. Supported values are chat, code, image, voice, and agent.

data-locale

Optional locale hint for creative selection and disclosures, for example en-US or de-DE.

data-prompt-topic / data-prompt-text

Optional contextual hints passed into the initial job request.

data-native-template

Optional native renderer preset. Stage 1 supports default and compact.

data-api-base-url

Optional override for non-production environments. Defaults to https://api.wavebird.ai.

data-auto-discover-slots

Optional. Set false if you want to call renderAd() manually instead of auto-discovering [data-wavebird-slot] targets.

## Slot attributes

data-wavebird-slot

Marks an element as an auto-discovered render target for the next available slot.

data-wavebird-position

Optional slot placement hint. Supported values are above, below, sidebar, and between.

data-wavebird-max-width / data-wavebird-max-height

Optional sizing constraints used when the renderer reserves space for banner, clip, or native placements.

data-wavebird-formats

Optional comma-separated format hint such as banner,native or clip.

data-wavebird-prompt-topic / data-wavebird-prompt-text

Optional per-slot prompt hints when different placements should use different sponsor context.

## Script Tag methods

init(config)

Initializes the global controller, refreshes browser activation, loads public app config, and auto-discovers slots by default.

createJob(options)

Creates a browser job and returns jobId plus slotIds using the compatibility browser flow behind the scenes.

renderAd({ slotId, target, waitMs? })

Polls the canonical /v1/decisions/{slot_id} route, renders banner, clip, or native output, and wires beacons automatically.

setConsent(tcfString)

Seeds a stored TCF string for advanced custom consent flows before the next createJob call.

on(event, handler)

Subscribes to lifecycle events such as ready, ad:rendered, consent:required, and error.

## Script Tag events

ready

Fires after init() resolves the active client configuration and browser activation context.

job:created / decision:loaded

Useful for custom debugging, analytics hooks, and sandbox observability.

ad:rendered / ad:empty

Signals whether a slot rendered a creative or resolved as no-fill.

clip:play_started / clip:play_completed / clip:autoplay_blocked

Clip-only playback lifecycle events surfaced by the Stage 1 renderer.

consent:required / consent:submitted

Raised when the built-in wavebird consent flow needs user input or has stored a new consent state.

error

Non-fatal runtime errors surfaced with a stable code and message for debugging.

## Rate limits

Per-key limits

All canonical v1 routes enforce per-key rate limits with burst and sustained buckets.

Browser IP limits

Activation-backed browser traffic adds looser per-IP shaping on top of the publishable-key limit.

429 behavior

Rate-limited responses include the standard Retry-After header and the canonical error envelope.

Previous

Versioning

Next

Request IDs

## Need rollout review?

Start with the Server API. Use contact only when you need rollout review, enterprise coordination, or non-standard integration help.Contact the team
