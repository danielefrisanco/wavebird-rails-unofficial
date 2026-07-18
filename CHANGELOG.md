# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `Wavebird::Types` value objects mirroring the upstream public contracts
  field-for-field: `PlacementResponse` (null placement = first-class no-fill),
  `Placement`, `Render`, `Decision` (pending/no-fill/fill variants),
  `Creative`, `NativeAssets`, `AcceptedJob`, `BeaconResult`, `ConsentState`,
  `ProjectConfig`. Tolerant reads (unknown fields kept in `raw`), and
  `asset_token`/`frame_url` redacted from all inspection output.
- `Wavebird::Configuration` + `Wavebird.configure`: defaults and numeric
  clamping mirroring the upstream TS SDK (`timeout_ms`, `decision_timeout_ms`,
  `long_poll_wait_ms`, `short_poll_interval_ms`), HTTPS-except-localhost base
  URL validation, callable secret key support, secret redaction in `inspect`.
- `Wavebird::Error` hierarchy: typed exceptions per API error code
  (`unauthorized`, `forbidden`, `rate_limited` with `retry_after`,
  `validation_error`, `not_found`), transport errors, `request_id`/`docs_url`/
  `http_status` on every error.
- Gem skeleton: gemspec, module layout, test/lint tooling, CI.
