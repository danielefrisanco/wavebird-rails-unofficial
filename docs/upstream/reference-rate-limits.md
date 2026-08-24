<!-- Snapshot of https://wavebird.ai/api/reference/rate-limits taken 2026-07-18; extracted from HTML, formatting approximate. -->

Search API docs/

Reference

# Rate limits

Rate limits are applied per key bucket. 429 responses include Retry-After.

## Buckets

Sandbox/test keys and production keys use separate operational buckets. Do not assume test traffic exercises live limits.

## 429 behavior

When limited, retry after the Retry-After header and avoid tight polling loops on decisions.

## Dashboard visibility

Use dashboard logs and metrics to diagnose rate-limit hits where available. Full usage-against-limit surfacing remains a product follow-up.

Previous

Errors

Next

Versioning

## Need rollout review?

Start with the Server API. Use contact only when you need rollout review, enterprise coordination, or non-standard integration help.Contact the team
