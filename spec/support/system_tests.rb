# frozen_string_literal: true

# Phase 8 system-test harness: boots spec/dummy and drives it through headless
# Chrome, so the browser glue from Phases 6a/6b is exercised for real.
#
# Loaded lazily — only when a system spec actually runs — so the fast unit suite
# does not pay for Rails, Capybara or a browser. See spec/spec_helper.rb.
require "capybara/rspec"
require "selenium-webdriver"

# Selenium logs every wire call at INFO; keep the suite output readable.
Selenium::WebDriver.logger.level = :error

require_relative "../dummy/config/application"
Dummy::Application.initialize! unless Dummy::Application.initialized?

# Chrome needs to reach the Capybara server; everything else stays blocked so a
# stray request to the real wavebird API still fails loudly. Registered stubs
# take precedence over this allowance, so the server-side /v1/* calls are still
# intercepted even though they share the Capybara host.
WebMock.disable_net_connect!(allow_localhost: true)

# Prefer an explicitly configured chromedriver, then one matching the installed
# Chrome. Without this, Selenium picks the first chromedriver on PATH, which on a
# developer machine is often a stale version that cannot drive current Chrome.
# Falls through to Selenium Manager (which downloads a match) when none is found.
#
# The match is deliberately *not* strict equality. Chrome auto-updates far more
# often than a system chromedriver package, so insisting on an exact major
# rejected a driver one version behind and fell back to PATH — which on this
# machine meant a driver 38 majors stale, i.e. a worse choice made confidently.
# A small skew is tolerated, and the closest candidate wins.
CHROMEDRIVER_MAX_SKEW = 2

def wavebird_chromedriver_candidates
  [ENV.fetch("CHROMEDRIVER_PATH", nil), "/usr/bin/chromedriver", "/usr/local/bin/chromedriver"]
    .compact.select { |path| File.executable?(path) }
end

def wavebird_chromedriver_path
  candidates = wavebird_chromedriver_candidates
  chrome = major_version(`google-chrome --version 2>/dev/null`)
  return candidates.first if chrome.nil?

  candidates.filter_map { |path| wavebird_driver_skew(path, chrome) }
            .min_by(&:last)&.first
end

# [path, distance-from-installed-Chrome], or nil when unusable.
def wavebird_driver_skew(path, chrome)
  major = major_version(`#{path} --version 2>/dev/null`)
  return nil if major.nil?

  skew = (major - chrome).abs
  [path, skew] if skew <= CHROMEDRIVER_MAX_SKEW
end

def major_version(version_output)
  version_output[/\d+/]&.to_i
end

Capybara.register_driver :wavebird_headless_chrome do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  options.add_argument("--headless=new")
  options.add_argument("--no-sandbox")
  options.add_argument("--disable-dev-shm-usage")
  options.add_argument("--disable-gpu")
  options.add_argument("--window-size=1400,1400")

  driver_path = wavebird_chromedriver_path
  service = driver_path ? Selenium::WebDriver::Service.chrome(path: driver_path) : nil

  Capybara::Selenium::Driver.new(app, browser: :chrome, options: options, service: service)
end

Capybara.configure do |config|
  config.default_driver = :wavebird_headless_chrome
  config.javascript_driver = :wavebird_headless_chrome
  config.app = Dummy::Application
  config.server = :puma, { Silent: true }
  config.default_max_wait_time = 5
end

# Shared setup for every system spec: credentials, a clean slate, and the
# WebMock stubs the dummy's server-side controller will hit.
RSpec.shared_context "with the dummy chat app" do
  # The gem builds the renderer's <script src> from api_base_url. Pointing it at
  # the Capybara server makes `wavebird_render_script_tag` resolve to the local
  # render.js stand-in, so the specs exercise the gem's real helper rather than a
  # hand-placed script tag. Server-to-server API calls are stubbed at this same
  # host by the helpers below.
  before do
    Wavebird.configure do |c|
      c.secret_key = "sk_test_system_spec"
      c.client_id = "wbproj_system_spec"
      c.api_base_url = api_base_url
      # Every host needs this or the hosted renderer refuses every turn (#030).
      # Configured here rather than in the dummy app so a spec can override or
      # remove it to exercise the gate itself.
      c.authoritative_consent = -> { system_spec_consent }
    end
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    ActiveJob::Base.queue_adapter.performed_jobs.clear
  end

  after do
    Wavebird.reset_configuration!
    Capybara.reset_sessions!
  end

  # A grant the renderer accepts: `granted`, revision >= 1, and an expiry far
  # enough out that a slow suite cannot age past it.
  def system_spec_consent
    { lifecycle_state: "granted", expires_at_ms: (Time.now.to_i + 3600) * 1000 }
  end

  # Base URL of the Capybara-served dummy app; also the configured
  # `api_base_url`, so the renderer script tag resolves to the local stand-in.
  #
  # Capybara boots its server lazily, so this must be read *after* the session
  # exists — `Capybara.current_session.server` forces the boot and exposes the
  # real port (Capybara.server_port is 0 until then).
  def api_base_url
    server = Capybara.current_session.server
    "http://#{server.host}:#{server.port}"
  end

  # POST /v1/placements — the blocking path's upstream call.
  def stub_placement(body)
    stub_request(:post, "#{api_base_url}/v1/placements")
      .with(query: hash_including({}))
      .to_return(status: 200, body: JSON.generate(body),
                 headers: { "Content-Type" => "application/json" })
  end

  # POST /v1/jobs — the async path's non-blocking job creation.
  def stub_job(slot_id: "slot_1")
    stub_request(:post, "#{api_base_url}/v1/jobs")
      .with(query: hash_including({}))
      .to_return(status: 200,
                 body: JSON.generate("job_id" => "job_1", "slot_ids" => [slot_id],
                                     "status" => "accepted"),
                 headers: { "Content-Type" => "application/json" })
  end

  # A filled placement response carrying hosted-frame render instructions.
  def fill_body(frame_url: "https://api.wavebird.ai/v1/render/at_secret_proof")
    {
      "slot_id" => "slot_1", "status" => "ready",
      "placement" => {
        "asset_token" => "at_secret_proof", "format" => "banner",
        "render" => {
          "strategy" => "hosted_frame", "frame_url" => frame_url,
          "script_url" => "https://api.wavebird.ai/v1/render.js",
          "width" => 728, "height" => 90,
          "label_text" => "Sponsored", "sponsor_name" => "Acme"
        }
      },
      "decision" => { "fill" => true, "asset_token" => "at_secret_proof" }
    }
  end

  def no_fill_body
    { "slot_id" => "slot_1", "status" => "no_fill", "placement" => nil, "decision" => nil }
  end

  # Waits for the layout's module script to finish wiring Stimulus.
  def wait_for_dummy_ready
    Timeout.timeout(Capybara.default_max_wait_time) do
      sleep 0.05 until page.evaluate_script("window.__dummyReady === true")
    end
  end

  def slot
    find("#wavebird-slot-below", visible: :all)
  end
end

require "active_job/test_helper"

RSpec.configure do |config|
  config.include_context "with the dummy chat app", type: :system
  # Gives the async specs `perform_enqueued_jobs`, so a spec can run the poll job
  # exactly where a queue worker would.
  config.include ActiveJob::TestHelper, type: :system
end
