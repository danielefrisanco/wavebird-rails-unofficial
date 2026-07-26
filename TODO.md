# TODO

## data_redactor as an optional integration

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

Caller redacts before handing the prompt to the client:

```ruby
client.create_job(
  job_type: "chat",
  context: { topic: "cloud deployment" },
  prompt: { text: DataRedactor.redact(user_prompt) }
)
```

**Requirement this places on Phase 4:** `prompt` must stay reachable and
transformable by the caller before send. No implicit redaction inside the gem
— the client stays a faithful forwarder (as upstream is, see
`wavebird-client.ts:297-307`), the policy stays the user's.

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
