# wavebird-rails

> **Status: pre-release, under active development.** Nothing here is published
> to RubyGems yet; the public API is not stable.

Server-side API client and Hotwire integration for
[wavebird](https://wavebird.ai) — "Compute Sponsoring" ad infrastructure for
AI products. Lets Rails chat apps, copilots, and agents show contextual
sponsored placements alongside AI-generated responses without sending prompts,
chat history, or user PII to the ad network.

This gem is a Ruby/Rails port started from the original public
[wavebird TypeScript SDK](https://github.com/wavebird-ai/wavebird) (MIT), and
targets wavebird's canonical REST v1 API — the
[official docs](https://wavebird.ai/api) are the source of truth.

## Development

```sh
bundle install
bundle exec rake   # rspec + rubocop
```

Project working agreement: see `WAY_OF_WORK.md`. Decisions: `docs/DECISIONS.md`.
Port parity vs the original SDK: `docs/parity.md`.

## License

MIT — see `LICENSE.txt`. Credits: [wavebird](https://wavebird.ai) and the
original [wavebird SDK](https://github.com/wavebird-ai/wavebird).
