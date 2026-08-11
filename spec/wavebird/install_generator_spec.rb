# frozen_string_literal: true

require "rails/generators"
require "generators/wavebird/install/install_generator"
require "fileutils"
require "tmpdir"

RSpec.describe Wavebird::Generators::InstallGenerator do
  let(:destination) { Dir.mktmpdir("wavebird-install") }

  before { FileUtils.mkdir_p(File.join(destination, "config")) }
  after { FileUtils.remove_entry(destination) }

  # Runs the generator against a throwaway app skeleton and returns what it
  # printed, so the "skip" paths can be asserted on rather than inferred.
  def capture_output(args)
    captured = StringIO.new
    original = $stdout
    $stdout = captured
    described_class.start(args, destination_root: destination)
    captured.string
  ensure
    $stdout = original
  end

  def write(path, content)
    full = File.join(destination, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def read(path) = File.read(File.join(destination, path))

  def exist?(path) = File.exist?(File.join(destination, path))

  def routes_file
    <<~RUBY
      Rails.application.routes.draw do
        root "chats#show"
      end
    RUBY
  end

  def application_controller
    <<~RUBY
      class ApplicationController < ActionController::Base
      end
    RUBY
  end

  describe "a fresh install" do
    before do
      write("config/routes.rb", routes_file)
      write("app/controllers/application_controller.rb", application_controller)
      capture_output([])
    end

    it "mounts the engine in config/routes.rb" do
      expect(read("config/routes.rb")).to include('mount Wavebird::Engine => "/wavebird"')
    end

    it "writes the initializer" do
      expect(read("config/initializers/wavebird.rb")).to include("Wavebird.configure")
    end

    # The initializer is the file a host edits, so it must arrive documented
    # rather than as a bare skeleton.
    it "documents the credential source and the fail-silent hook in the initializer" do
      initializer = read("config/initializers/wavebird.rb")

      expect(initializer).to include("Rails.application.credentials.dig(:wavebird, :secret_key)")
      expect(initializer).to include("config.on_error")
    end

    # The one file the gem's Railtie refuses to boot from is an asset path, so
    # the generated initializer says so where a reader will see it.
    it "warns in the initializer against moving it under an asset path" do
      expect(read("config/initializers/wavebird.rb")).to include("app/javascript")
    end

    it "opts ApplicationController into the helpers and the session id" do
      controller = read("app/controllers/application_controller.rb")

      expect(controller).to include("helper Wavebird::SlotHelper")
      expect(controller).to include("include Wavebird::SessionId")
    end
  end

  describe "idempotence" do
    before do
      write("config/routes.rb", routes_file)
      write("app/controllers/application_controller.rb", application_controller)
      capture_output([])
    end

    it "does not mount the engine twice" do
      capture_output([])

      expect(read("config/routes.rb").scan("Wavebird::Engine").length).to eq(1)
    end

    it "does not wire ApplicationController twice" do
      capture_output([])

      expect(read("app/controllers/application_controller.rb").scan("Wavebird::SlotHelper").length).to eq(1)
    end

    it "reports what it skipped rather than staying silent" do
      output = capture_output([])

      expect(output).to include("already mounted")
      expect(output).to include("already wired")
    end
  end

  describe "a partial or unconventional app" do
    # A host that mounted the engine by hand should still get the initializer and
    # the controller wiring, rather than the generator refusing or duplicating.
    it "fills in only what is missing when the engine is already mounted" do
      write("config/routes.rb", "Rails.application.routes.draw do\n  mount Wavebird::Engine => \"/ads\"\nend\n")
      write("app/controllers/application_controller.rb", application_controller)

      capture_output([])

      expect(read("config/routes.rb")).not_to include("/wavebird")
      expect(read("app/controllers/application_controller.rb")).to include("Wavebird::SlotHelper")
    end

    # An API-only app has no ApplicationController at that path. That is not an
    # error: the engine and initializer are still useful, so it says so and moves on.
    it "skips the controller when the app has none, without failing" do
      write("config/routes.rb", routes_file)

      output = capture_output([])

      expect(output).to include("no app/controllers/application_controller.rb")
      expect(exist?("config/initializers/wavebird.rb")).to be(true)
    end

    it "mounts at a custom prefix" do
      write("config/routes.rb", routes_file)
      write("app/controllers/application_controller.rb", application_controller)

      capture_output(["--mount-at=/sponsored"])

      expect(read("config/routes.rb")).to include('mount Wavebird::Engine => "/sponsored"')
    end

    # routes.rb missing entirely: `route` would create it, and the mount check
    # must not blow up on a file that is not there.
    it "tolerates a missing config/routes.rb" do
      write("app/controllers/application_controller.rb", application_controller)

      expect { capture_output([]) }.not_to raise_error
    end
  end

  describe "the printed next steps" do
    before do
      write("config/routes.rb", routes_file)
      write("app/controllers/application_controller.rb", application_controller)
    end

    # The generator deliberately does not edit views or JS, so the two steps it
    # cannot take must be printed in full rather than linked to.
    it "prints the slot markup and the turn wiring" do
      output = capture_output([])

      expect(output).to include("wavebird_slot endpoint:")
      expect(output).to include("window.wavebird?.withTurn")
    end

    # The plain path is what the docs lead with; the generator must not send
    # people to Stimulus, which needs pins and a controller registration.
    it "prints the plain-JavaScript path, not the Stimulus event" do
      output = capture_output([])

      expect(output).not_to include("wavebird:turn")
    end

    it "says the app works before the keys are configured" do
      expect(capture_output([])).to include("fails silently")
    end
  end
end
