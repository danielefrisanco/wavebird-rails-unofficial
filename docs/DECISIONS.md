# Decision log — wavebird-rails

Numbered, newest last. Every deviation from the upstream TS SDK, and every
TS↔Rails mismatch, gets an entry: context → options → decision → rationale.
Decisions that go against the original SDK require Daniele's approval first
(see WAY_OF_WORK.md).

| # | Date | Status | Decision |
|---|------|--------|----------|
| 001 | 2026-07-18 | approved | Async decision delivery via ActiveJob poll + Turbo Stream broadcast instead of porting `getDecisionViaWebSocket`. Rationale (verified in `wavebird-client.ts`): upstream's WS is per-decision and short-lived (ticket POST → open WS → wait for one message → close), with polling as its own trusted fallback — so a held long-poll `GET /v1/decisions/{slot_id}?wait_ms=` delivers equivalent push latency without a Ruby WS dependency. Browser↔Rails stays WebSocket via ActionCable/Turbo Streams. **Deferred todo:** implement the Rails↔wavebird WS transport behind the same interface in a later version (or if wavebird adds a persistent multi-slot channel). Poller must mirror upstream deadline semantics (`timing.ts`/`clamp.ts`, `decisionTimeoutMs`, long-poll attempt counts). Approved by Daniele. |
| 002 | 2026-07-18 | open | `reportGeneration()` exists in the TS SDK but not in the build prompt — port or skip? Needs investigation + Daniele's call. |
