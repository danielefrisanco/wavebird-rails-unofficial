# Decision log — wavebird-rails

Numbered, newest last. Every deviation from the upstream TS SDK, and every
TS↔Rails mismatch, gets an entry: context → options → decision → rationale.
Decisions that go against the original SDK require Daniele's approval first
(see WAY_OF_WORK.md).

| # | Date | Status | Decision |
|---|------|--------|----------|
| 001 | 2026-07-18 | approved | Async decision delivery via ActiveJob poll + Turbo Stream broadcast instead of porting `getDecisionViaWebSocket`. Rationale (verified in `wavebird-client.ts`): upstream's WS is per-decision and short-lived (ticket POST → open WS → wait for one message → close), with polling as its own trusted fallback — so a held long-poll `GET /v1/decisions/{slot_id}?wait_ms=` delivers equivalent push latency without a Ruby WS dependency. Browser↔Rails stays WebSocket via ActionCable/Turbo Streams. **Deferred todo:** implement the Rails↔wavebird WS transport behind the same interface in a later version (or if wavebird adds a persistent multi-slot channel). Poller must mirror upstream deadline semantics (`timing.ts`/`clamp.ts`, `decisionTimeoutMs`, long-poll attempt counts). Approved by Daniele. |
| 002 | 2026-07-18 | approved | `reportGeneration()` exists in the TS SDK but not in the build prompt — port or skip? Investigated: canonical route `POST /v1/jobs/{job_id}/generation/{event}`, events `started\|finished\|failed`, body `generation_id`/`model_id`/`usage_json`/`error`, fire-and-forget. **Approved by Daniele: port in v1.** |
| 003 | 2026-07-18 | approved | **Error posture conflict** — TS SDK public methods never throw (fail-silent + `onError` observer); build prompt §3.9 demands typed exceptions per HTTP error code. **Approved by Daniele: layered** — low-level `Wavebird::Client` raises typed errors; Rails-facing facade is fail-silent like upstream. |
| 004 | 2026-07-18 | approved | `decisionDelivery: "callback"` mode (wavebird POSTs decision to a `callback_url`) — not in build prompt; an engine-mounted callback route would fit Rails well. **Approved by Daniele: later todo** — design client so it can slot in post-v1 without breaking changes. |
