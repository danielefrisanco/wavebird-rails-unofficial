<!-- Snapshot of https://wavebird.ai/api/reference/errors taken 2026-07-18; extracted from HTML, formatting approximate. -->

Search API docs/

Reference

# Error codes

Errors should tell you what went wrong, what to do next, where to read more, and the request_id for support.

## Envelope

JSON errors include an error code, message, docs_url when available, and request_id. The same request ID is returned in X-Request-Id.

## Common codes

Runtime error codes are lowercase. `unauthorized` means add valid credentials, `forbidden` means use the correct key type or origin, `rate_limited` means back off using Retry-After, `validation_error` means fix request body shape, and `not_found` means the resource is missing or outside the authenticated scope.

## Support

Include request_id, endpoint, key mode, and environment when asking for help. Never include full API keys.

Previous

Consent in GenAI apps

Next

Rate limits

## Need rollout review?

Start with the Server API. Use contact only when you need rollout review, enterprise coordination, or non-standard integration help.Contact the team
