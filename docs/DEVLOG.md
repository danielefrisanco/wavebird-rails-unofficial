# Devlog — wavebird-rails

Reverse chronological. Each entry: done / todo / problems found.

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
