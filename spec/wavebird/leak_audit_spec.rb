# frozen_string_literal: true

# Source-level audit (build plan Phase 7): no gem code path may interpolate the
# secret key or an asset token into a string that could reach a log, an
# exception message, an instrumentation payload or a rendered response.
#
# This complements — it does not replace — the runtime leak specs:
#   - instrumentation payload  (spec/wavebird/client_request_spec.rb)
#   - value-object #inspect    (spec/wavebird/types_spec.rb)
#   - configuration #inspect   (spec/wavebird/configuration_spec.rb)
#   - browser JSON             (spec/wavebird/sponsor_slots_controller_spec.rb)
#   - async broadcast payload  (spec/wavebird/decision_poll_job_spec.rb)
#
# Those prove the current behavior; this one fails fast if a future change
# introduces a new interpolation site anywhere in the gem.
RSpec.describe Wavebird do
  describe "sensitive-value leak audit" do
    let(:gem_root) { File.expand_path("../..", __dir__) }

    # Interpolations of a sensitive value into a string: "#{...secret_key...}".
    let(:sensitive_interpolation) do
      /\#\{[^}]*\b(?:secret_key|resolved_secret_key|asset_token)\b[^}]*\}/
    end

    # The only places a sensitive value may legitimately be interpolated, each
    # with the reason it is safe.
    let(:allowed) do
      {
        # The Authorization header — the one place the secret key is meant to
        # go, and it goes over TLS to wavebird, never to a log or the browser.
        "lib/wavebird/client.rb" => [/"Bearer \#\{require_secret_key\}"/],
        # The hosted-frame URL is built server-side from the asset token
        # precisely so the bare token never crosses to the browser (#009).
        "lib/wavebird/slot_payload.rb" => [/CGI\.escapeURIComponent\(asset_token\)/],
        # The redacting #inspect: the interpolation evaluates `secret_key.nil?`
        # and emits only the literal "nil" or "[REDACTED]" — the value never
        # lands in the string (asserted at runtime in configuration_spec.rb).
        "lib/wavebird/configuration.rb" => [/secret_key\.nil\? \? 'nil' : '\[REDACTED\]'/]
      }
    end

    let(:ruby_sources) { Dir.glob(File.join(gem_root, "{lib,app}/**/*.rb")) }

    def offending_lines(file, gem_root:, pattern:, allowed:)
      relative = file.delete_prefix("#{gem_root}/")
      permitted = allowed.fetch(relative, [])

      File.readlines(file).each_with_index.filter_map do |line, index|
        next unless line.match?(pattern)
        next if permitted.any? { |allowance| line.match?(allowance) }

        "#{relative}:#{index + 1}: #{line.strip}"
      end
    end

    it "finds Ruby sources to audit" do
      expect(ruby_sources).not_to be_empty
    end

    it "never interpolates secret_key or asset_token outside the allowed sites" do
      offenders = ruby_sources.flat_map do |file|
        offending_lines(file, gem_root: gem_root, pattern: sensitive_interpolation, allowed: allowed)
      end

      expect(offenders).to be_empty, <<~MSG
        Sensitive value interpolated into a string outside the allowed sites:

        #{offenders.join("\n        ")}

        A secret key or asset token must never reach a log line, exception
        message, instrumentation payload or rendered response (build prompt §4).
        If this site is genuinely safe, add it to `allowed` with a rationale.
      MSG
    end

    it "keeps the logger lines free of interpolated sensitive values" do
      # Both fail-silent reporters log only "[wavebird] <ErrorClass>: <message>".
      logger_lines = ruby_sources.flat_map { |file| File.readlines(file).grep(/logger&?\.\w+\(/) }

      expect(logger_lines).not_to be_empty
      logger_lines.each { |line| expect(line).not_to match(sensitive_interpolation) }
    end
  end
end
