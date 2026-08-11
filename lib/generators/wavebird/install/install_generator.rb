# frozen_string_literal: true

require "rails/generators/base"

module Wavebird
  # Rails generators shipped with the gem, discovered by +rails generate+ from
  # +lib/generators+. They are host-app tooling, not part of the runtime API:
  # nothing here is loaded when the engine boots.
  module Generators
    # Wires wavebird-rails into a host app: mounts the engine, writes the
    # initializer, and opts +ApplicationController+ into the view helpers and the
    # anonymous session id.
    #
    #   rails generate wavebird:install
    #
    # Every step is idempotent and reports what it did, so running it twice is
    # safe and running it after a manual install only fills in what is missing.
    # It deliberately does **not** touch views or JavaScript: where a slot belongs
    # on the page, and which turn your app hands to wavebird, are decisions the
    # generator cannot make. It prints those two snippets instead.
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      # Path of the host's +ApplicationController+. Declared above +private+
      # because constants ignore it — a constant under +private+ is still public,
      # and RuboCop flags the misleading placement.
      CONTROLLER_PATH = "app/controllers/application_controller.rb"

      # The two lines injected into +ApplicationController+.
      CONTROLLER_LINES = <<~RUBY
        # The engine isolates its namespace, so opt views into its helpers.
        helper Wavebird::SlotHelper
        # Anonymous, unguessable per-browser session id (never a user id).
        include Wavebird::SessionId
      RUBY

      desc "Mounts the wavebird engine, writes config/initializers/wavebird.rb, " \
           "and wires ApplicationController."

      class_option :mount_at, type: :string, default: "/wavebird",
                              desc: "Path prefix to mount the engine at"

      # Path prefix the engine is mounted at, e.g. +/wavebird+.
      # @return [String]
      def mount_at
        options[:mount_at]
      end

      # Adds the engine mount to +config/routes.rb+ unless it is already there.
      # @return [void]
      def mount_engine
        return say_status(:skip, "engine already mounted in config/routes.rb", :yellow) if engine_mounted?

        route(%(mount Wavebird::Engine => "#{mount_at}"))
      end

      # Writes +config/initializers/wavebird.rb+. Thor prompts before overwriting
      # an existing one, so a customised initializer is never clobbered silently.
      # @return [void]
      def create_initializer
        template("initializer.rb.tt", "config/initializers/wavebird.rb")
      end

      # Opts +ApplicationController+ into the slot helpers and the anonymous
      # session id — the two lines every host app needs.
      # @return [void]
      def wire_application_controller
        return say_status(:skip, "no app/controllers/application_controller.rb", :yellow) unless controller?
        return say_status(:skip, "ApplicationController already wired", :yellow) if controller_wired?

        inject_into_class(CONTROLLER_PATH, "ApplicationController", CONTROLLER_LINES)
      end

      # Prints the two steps the generator cannot make for you.
      # @return [void]
      def print_next_steps
        say("\n#{next_steps}\n")
      end

      private

      # Resolve against the app being generated into, never the process CWD.
      # Thor's file *actions* are destination-relative, but plain File reads are
      # not — checking "config/routes.rb" from inside this gem inspects the gem's
      # own routes, which mount the engine, so every install would skip itself.
      def app_path(relative) = File.expand_path(relative, destination_root)

      def routes_path = app_path("config/routes.rb")

      def engine_mounted?
        File.exist?(routes_path) && File.read(routes_path).include?("Wavebird::Engine")
      end

      def controller? = File.exist?(app_path(CONTROLLER_PATH))

      def controller_wired?
        File.read(app_path(CONTROLLER_PATH)).include?("Wavebird::SlotHelper")
      end

      def next_steps
        <<~TEXT
          wavebird is installed. Two steps left — both need a decision only you can make:

          1. Put a slot where you want the sponsored unit, in the view with your chat:

               <%= wavebird_render_script_tag %>
               <%= wavebird_slot endpoint: wavebird.sponsor_slot_path,
                                 session_id: wavebird_session_id,
                                 position: "below" %>

          2. Hand your chat turn to wavebird, so the placement is auctioned while
             your answer generates:

               const slot = document.querySelector("#wavebird-slot-below");
               const send = () => sendChatMessage(message);

               if (window.wavebird?.withTurn) {
                 window.wavebird.withTurn(
                   { target: slot,
                     body: { session_id: slot.dataset.wavebirdSessionIdValue,
                             position: slot.dataset.wavebirdPositionValue } },
                   send,
                 );
               } else {
                 send();
               }

          Add your keys to config/initializers/wavebird.rb and you are done. Until
          then the client fails silently: the slot stays hidden and your app works.

          A runnable end-to-end example: examples/single_file_chat.rb in the gem.
        TEXT
      end
    end
  end
end
