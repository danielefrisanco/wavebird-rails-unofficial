<!-- Snapshot of https://wavebird.ai/api/reference/versioning taken 2026-07-18; extracted from HTML, formatting approximate. -->

Search API docs/

# Versioning 

Wavebird docs currently describe the stable API v1 surface. The public base path is `/v1`, and the current canonical docs live at `/api` with stable reference aliases under `/api/v1`. 

V1 launch policy

Breaking API changes should be announced in the changelog before partners depend on them. Compatibility aliases can remain available, but new snippets should use canonical `/v1/*` routes. 

## Current version 

Use `https://api.wavebird.ai/v1/*` for production requests. The API reference documents the canonical v1 endpoints: placements, hosted rendering, browser activation, advanced jobs and decisions, beacons, consent, and project config. 

## Compatibility routes 

Script Tag and SDK compatibility routes may continue to exist for older integrations. They are not the preferred public docs surface for new partners. 

## Future versions 

There is no version selector in v1. Add one when a future `/v2` or breaking behavior change is planned, then keep `/api` pointed at the current stable version.

## Need rollout review?

Start with the Server API. Use contact only when you need rollout review, enterprise coordination, or non-standard integration help.Contact the team
