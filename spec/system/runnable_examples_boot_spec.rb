# frozen_string_literal: true

require "net/http"
require "socket"
require "base64"
require "json"
require "timeout"
require "tempfile"

# Plan v2 items G3-G4: the half of "test the examples" that actually starts them.
#
# `spec/wavebird/runnable_examples_spec.rb` reads these two files as text and as
# an AST, which catches a syntax error or a mangled template but cannot tell you
# whether the app *works*. This spec boots each one for real and talks to it over
# HTTP -- the assertion the plan says "would have caught every bug found by hand".
#
# Deliberately no Capybara and no `spec/dummy`: this file does not
# `require_relative "../support/system_tests"`, so nothing here needs a browser or
# a second Rails application. It lives in spec/system only because it is slow
# (~10s per example) and because that process has no Rails app of its own to
# collide with. Each example runs as a **subprocess** -- the examples define their
# own `Rails::Application`, and only one may exist per process.
EXAMPLES_DIR = File.expand_path("../../examples", __dir__)
EXAMPLE_BOOT_TIMEOUT = 60

# spec_helper blocks every outbound connection; these specs must reach the
# subprocess on 127.0.0.1. Set once at file level, exactly as support/system_tests.rb
# does for Capybara -- deliberately NOT toggled per example around a restore.
#
# The first version of this file did restore, with `WebMock.disable_net_connect!`
# in an `ensure`. Every example here passed in isolation and six Capybara
# examples failed when the suite ran together: the "restore" put back
# spec_helper's stricter default rather than the value system_tests.rb had
# established, cutting off chromedriver at 127.0.0.1:9515. Whoever runs last
# wins is not a thing to be clever about -- both files want the same setting, so
# both just declare it.
WebMock.disable_net_connect!(allow_localhost: true)

RSpec.describe "examples/*.rb booted for real", :aggregate_failures do
  # Ask the OS for an unused port and hand it straight back. There is a race
  # between closing this and the example binding, which is why the port is not
  # hardcoded: a collision here retries on the next run, a hardcoded 3000
  # collides with whatever the developer already has running.
  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  # Boots one example, yields its base URL, and always reaps the process.
  def boot_example(basename)
    port = free_port
    log = Tempfile.new(["#{basename}-", ".log"])
    # A blank key is what makes this safe to run anywhere: the client is
    # fail-silent, so the app serves and the slot no-fills without ever calling
    # wavebird. Setting the variables (rather than leaving them unset) also stops
    # the example's optional `Dotenv.load` from supplying a real sandbox key from
    # a developer's .env.test -- dotenv never overwrites an existing value.
    env = { "PORT" => port.to_s, "WAVEBIRD_SECRET_KEY" => "", "WAVEBIRD_CLIENT_ID" => "" }
    pid = Process.spawn(env, Gem.ruby, File.join(EXAMPLES_DIR, basename),
                        out: log.path, err: %i[child out])

    base_url = "http://127.0.0.1:#{port}"
    await_boot(base_url, pid, log)
    yield base_url
  ensure
    terminate(pid)
    log&.close!
  end

  def await_boot(base_url, pid, log)
    Timeout.timeout(EXAMPLE_BOOT_TIMEOUT) do
      loop do
        raise "example exited during boot:\n#{File.read(log.path)}" if Process.waitpid(pid, Process::WNOHANG)

        break if (get(base_url) rescue nil)&.code == "200" # rubocop:disable Style/RescueModifier

        sleep 0.25
      end
    end
  rescue Timeout::Error
    raise "example did not answer within #{EXAMPLE_BOOT_TIMEOUT}s:\n#{File.read(log.path)}"
  end

  def terminate(pid)
    return if pid.nil?

    Process.kill("TERM", pid)
    Process.waitpid(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil # already gone
  end

  def get(url)
    Net::HTTP.get_response(URI(url))
  end

  def post_json(url, payload)
    uri = URI(url)
    Net::HTTP.post(uri, JSON.generate(payload), "Content-Type" => "application/json")
  end

  # The two assertions every example must satisfy, whichever path it demonstrates.
  shared_examples "a runnable wavebird example" do |basename|
    it "serves a page carrying a hidden, endpoint-wired slot" do
      boot_example(basename) do |base_url|
        response = get("#{base_url}/")
        expect(response.code).to eq("200")

        slot = response.body[/<section[^>]*id="wavebird-slot-below"[^>]*>/]
        expect(slot).not_to be_nil, "no wavebird slot section in the rendered page"
        # Hidden until the renderer fills it -- an unfilled slot must not leave a
        # gap in the host's page (#003).
        expect(slot).to include("hidden")
        expect(slot).to include('data-wavebird-endpoint="/wavebird/sponsor_slot"')
        # Anonymous per-browser token, never a user id.
        expect(slot).to match(/data-wavebird-session-id-value="sess_[^"]+"/)
      end
    end

    it "answers the sponsor-slot endpoint with a plain no-fill when unconfigured" do
      boot_example(basename) do |base_url|
        response = post_json("#{base_url}/wavebird/sponsor_slot",
                             session_id: "sess_spec", position: "below")

        # The whole fail-silent posture in one assertion: no key configured, and
        # the host still gets a well-formed 200 rather than a 500 in their chat.
        expect(response.code).to eq("200")
        expect(JSON.parse(response.body)).to eq("fill" => false)
      end
    end
  end

  describe "chat_plain.rb" do
    it_behaves_like "a runnable wavebird example", "chat_plain.rb"

    it "renders no Turbo stream, since the plain path has no async mode" do
      boot_example("chat_plain.rb") do |base_url|
        body = get("#{base_url}/").body

        expect(body).not_to include("turbo-cable-stream-source")
        expect(body).not_to include("data-wavebird-mode-value")
      end
    end
  end

  describe "chat_react.rb" do
    it_behaves_like "a runnable wavebird example", "chat_react.rb"

    # The React path loads React, ReactDOM and htm from a CDN as ES modules, so
    # nothing here can execute it -- the boot spec makes no browser. What it can
    # pin is that the page ships the mount points the script expects, and that
    # the slot is NOT inside either of them: React rendering into the slot would
    # let it clobber whatever the hosted renderer mounts there, which is the one
    # structural thing a React host has to get right.
    it "keeps the wavebird slot outside both React roots" do
      boot_example("chat_react.rb") do |base_url|
        body = get("#{base_url}/").body

        expect(body).to include('id="chat-root"')
        expect(body).to include('id="status-root"')

        slot_at = body.index('id="wavebird-slot-below"')
        chat_at = body.index('id="chat-root"')
        status_at = body.index('id="status-root"')

        expect(slot_at).not_to be_nil
        # Both roots are empty divs, so "outside" is provable by position: the
        # slot sits between them, in neither one's subtree.
        expect(chat_at).to be < slot_at
        expect(slot_at).to be < status_at
      end
    end
  end

  describe "chat_hotwire.rb" do
    it_behaves_like "a runnable wavebird example", "chat_hotwire.rb"

    # G4. #015: a position-only stream name is shared by every visitor rendering
    # that position, so one visitor's decision -- including the frame_url that
    # embeds their asset_token -- would be delivered to all of them and fire
    # their beacons from unrelated browsers. Until now that property was proven
    # for this example only by a curl run once, by hand.
    it "subscribes to a session-scoped stream, not a position-only one" do
      boot_example("chat_hotwire.rb") do |base_url|
        first = get("#{base_url}/").body
        second = get("#{base_url}/").body

        expect(first).to include('data-wavebird-mode-value="async"')

        names = [first, second].map { |body| body[/signed-stream-name="([^"]+)"/, 1] }
        expect(names).to all(be_a(String))

        # Turbo signs the name; the payload is the stream name itself, JSON
        # serialized. Asserted with `include` rather than `start_with` so this
        # stays about the scoping and not about the verifier's serializer.
        stream = Base64.strict_decode64(names.first.split("--").first)
        expect(stream).to include("wavebird_slot_below_")
        expect(stream).to include("sess_"), "stream name is position-only: #{stream.inspect}"

        # Two visitors, two streams. This is the assertion that fails if the
        # scoping regresses to position-only, whatever the name looks like.
        expect(names.first).not_to eq(names.last)
      end
    end
  end
end
