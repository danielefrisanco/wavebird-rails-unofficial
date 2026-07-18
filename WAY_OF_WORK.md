# Way of Work — wavebird-rails

Agreed 2026-07-18 between Daniele Frisanco and Claude. These rules override
convenience. When in doubt about the rules themselves: ask Daniele.

## Goal

A consistent, equivalent port of the original wavebird TypeScript SDK
(https://github.com/wavebird-ai/wavebird, MIT, currently v0.1.5) to Ruby/Rails —
not just API-equivalent, but **behaving in the most similar way** to the
original. The build prompt (`wavebird-rails-build-prompt.md`) was only a
starting point; the upstream SDK source and public docs are the source of truth.

## Rules

1. **No assumptions, no guessing.** Every contract detail is verified against
   the upstream source (`upstream/wavebird/`) or the public docs. If it can't
   be verified, ask Daniele — never invent.
2. **Clarity first.** Aim for the clearest possible code; idiomatic, boring,
   readable Ruby beats clever Ruby.
3. **Behavioral equivalence.** Same defaults, same error behavior, same
   fail-silent posture as the original client, unless a recorded decision says
   otherwise.
4. **Deviations require approval.** Any decision that goes against the original
   SDK is asked to Daniele *before* implementing, then recorded.
5. **Record decisions** in `docs/DECISIONS.md` (numbered, dated, with context
   and rationale). TS-specific things that make no sense in Rails (and vice
   versa) are written down there and decided together.
6. **Keep a devlog** in `docs/DEVLOG.md`: what was done, what is todo, problems
   found while developing.
7. **Branches.** All work happens on feature branches, merged when green.
   Commits small and meaningful; don't bloat git (no vendored artifacts, no
   giant WIP dumps, `upstream/` stays gitignored).
8. **Industry standard, up to date.** Well-known current techniques and tools
   only (RSpec, WebMock, RuboCop, SimpleCov, Hotwire, ActiveJob, GitHub
   Actions, Keep a Changelog, ADR-style decision records).
9. **No shortcuts.** No skipped tests, no "temporary" hacks, no TODO-instead-
   of-doing when the doing is in scope.
10. **No hardcoded configuration or secrets.** Ever — including tests. Test
    credentials come from a gitignored `.env.test` (dotenv), with a committed
    `.env.test.example` documenting required keys with placeholder values.
11. **Versioning:** semver. Upstream is at 0.1.5; we track a similar number —
    start at 0.1.0 and converge as parity lands.
12. **Attribution.** Authors: Daniele Frisanco and Claude (commits include
    `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`). README and
    gemspec explicitly acknowledge the project started from wavebird's original
    public SDK (https://github.com/wavebird-ai/wavebird) and link
    https://wavebird.ai as canonical.

## Interaction protocol

- A **question** from Daniele gets an **answer only** — no acting on it.
- Action happens only when Daniele says to do it / authorizes it.
- Be concise. Think and verify before writing code or replying.
