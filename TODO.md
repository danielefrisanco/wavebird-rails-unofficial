# TODO

## `bundle exec rake` exited 1, and had for a while — **fixed 2026-08-07**

Kept as a record: the fix is a two-line config change, but what it was hiding is
worth remembering.

**Symptom.** The default gate failed on 7 RuboCop offenses, all of them in
`tmp/chatdemo/` — the scratch host app from the 2026-08-04 live sandbox run.
That directory is gitignored (`.gitignore:15`), so these are offenses in
untracked scratch code that no one ships.

**Why it matters more than 7 style offenses.** `default` is
`%i[spec spec:system rubocop yard_coverage]`, so RuboCop failing means
**`yard_coverage` never runs**. The gate has therefore not been checking YARD
coverage at all — it aborts one task earlier. Gem code itself is clean
(`bundle exec rubocop lib/ spec/` → 49 files, no offenses) and YARD is at
100.00% when run by hand, so nothing is actually wrong with the gem; the gate
just stopped being a signal. A permanently-red gate is worse than no gate,
because it trains you to read `rake` output for the parts you trust.

**Root cause — not the demo code.** RuboCop's own default `AllCops: Exclude` is:

```yaml
- 'node_modules/**/*'
- 'tmp/**/*'
- 'vendor/**/*'
- '.git/**/*'
```

`.rubocop.yml:8` declares its own `AllCops: Exclude` (`upstream`, `vendor`,
`gemfiles`), and **`Exclude` is replaced, not merged**. Declaring it dropped all
four defaults. `vendor/**/*` survived only because it happens to be re-listed by
hand; `tmp/**/*` was not, so the scratch app became lintable. `node_modules` and
`.git` are silently un-excluded too — not biting today, but they would in any
checkout that has them.

**Fix applied.** Restore the defaults rather than re-listing them, so this cannot
drift again:

```yaml
inherit_mode:
  merge:
    - Exclude

AllCops:
  Exclude:
    - "upstream/**/*"
    - "gemfiles/**/*"
```

`vendor/**/*` came out of the hand-written list — it is a default. Cleaning up
`tmp/chatdemo/` instead would have fixed the symptom and left the merge bug in
place for the next untracked directory.

`inherit_mode` is documented for `inherit_from`/`inherit_gem`, so whether it also
merges against RuboCop's built-in `default.yml` was verified rather than assumed:
`rubocop --list-target-files` went from 64 files to 60, with `tmp/`, `vendor/`,
`upstream/` and `gemfiles/` all at zero. The fallback, had it not held, was to
re-list the four defaults by hand.

**Verified.** `bundle exec rake` exits 0 and prints `100.00% documented` — the
first time the gate has reached that task. 421 unit examples at 100% line +
branch, 18 system, 60 files inspected with no offenses.

**Watch for.** CI has never run (no remote yet), and the workflow runs
`bundle exec rake`. Whenever the repo is pushed, this failure is what the first
CI run reports, on all 10 matrix legs, unless it is fixed first.

## data_redactor as an optional integration — **done 2026-08-11**

Recommended in the README's privacy section ("Scrubbing PII before it leaves your
app"), with the two-hop table, both recipes, and an explicit note that it is not
and will not be a dependency. Kept here for the reasoning.

`data_redactor` (https://github.com/danielefrisanco/data_redactor) is a good
companion for wavebird-rails users who want PII scrubbing. **Recommend it in
the README — do not add it to the gemspec.** It ships a C extension, and
wavebird-rails should stay pure-Ruby with a light dependency footprint
(faraday, railties). Users opt in from their own app.

The gem's job is only to *expose the seams*; the host app wires the redactor.

### Why it's a separate concern from wavebird's "reduced signals"

Two different hops, two different owners:

| Concern | Owner | Where | What it does |
|---|---|---|---|
| Egress scrubbing | host app | hop 1, before send | strip PII so no CC/email/etc. reaches wavebird at all |
| Signal reduction | wavebird backend | hop 2 | rebuild a reduced request for ad buyers; prompt never forwarded |
| Log scrubbing | host app | logging boundary | keep PII out of the Rails log |

wavebird's guarantee covers hop 2 only (README.md:277-279 upstream). It says
nothing about hop 1 — that's the host app's egress control, and it's wanted
even when wavebird is fully trusted (defence in depth; possibly a compliance
requirement not to send card numbers to any third party).

`data_redactor` addresses rows 1 and 3. Both host-app side, both opt-in.

### Recipe 1 — egress scrubbing (hop 1)

Caller redacts before handing anything to the client:

```ruby
Wavebird.client.create_placement(
  job_type: "chat",
  session_id: session_id,
  topic: DataRedactor.redact(topic)
)
```

> **Corrected 2026-08-11.** This recipe was written in Phase 4 planning against
> a `context:` / `prompt: { text: }` shape that never shipped. The gem has no
> parameter that accepts user text at all — `topic:` takes a single coarse hint
> and nothing else (decision #019), which makes the surface for egress leaks much
> smaller than this section originally assumed. The README carries the accurate
> version.

**The requirement it placed on Phase 4 held:** whatever the caller sends stays
reachable and transformable before send. No implicit redaction inside the gem —
the client stays a faithful forwarder (as upstream is, `wavebird-client.ts:297-307`),
and the policy stays the user's.

### Recipe 2 — log scrubbing

Outbound job requests are nested hashes (`context`, `prompt`, `slot_config`),
so `redact_deep` is the right entry point. It walks values (not keys) and
returns a copy — so the redacted structure is what gets logged while the
original still goes to wavebird untouched.

```ruby
Wavebird.configure do |c|
  c.logger = RedactingLogger.new(Rails.logger) do |payload|
    DataRedactor.redact_deep(payload)
  end
end
```

This extends the redaction discipline already in `lib/wavebird/types.rb`
(`asset_token`, `frame_url` masked in `inspect`) from known-secret fields to
PII anywhere in free text. Choosing to send a prompt to wavebird shouldn't
also mean it lands in the Rails log.
