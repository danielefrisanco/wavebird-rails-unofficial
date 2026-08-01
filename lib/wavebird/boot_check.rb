# frozen_string_literal: true

require_relative "errors"

module Wavebird
  # Boot-time security guards (build prompt §4): the secret key must never be
  # reachable from an asset pipeline or browser bundle, and the gem should fail
  # *loudly* — raise at boot, not silently no-op — when a host wires it somewhere
  # that would expose it.
  #
  # Two independent checks, both raising {ConfigurationError}:
  #
  # 1. {assert_server_side_require!} — require-context guard. Runs when
  #    +wavebird+ is required and rejects a require originating from a host's
  #    +app/assets+ or +app/javascript+ tree (an asset-pipeline template or a
  #    bundled entrypoint), which is the literal case §4 names.
  # 2. {assert_assets_paths_safe!} — asset-path scan. Run from the {Railtie}
  #    initializer against the host's asset load paths; rejects any path that
  #    would make the gem's *server-side Ruby* servable as a static asset.
  #
  # Both are plain functions taking their inputs as arguments so they can be
  # unit-tested without booting a Rails application (the spec harness boots one
  # in-memory app per process and cannot boot a second).
  module BootCheck
    # Gem root — the directory containing +lib/+ and the browser-JS +app/+ tree.
    GEM_ROOT = File.expand_path("../..", __dir__)

    # Host directories that end up in a browser bundle or asset pipeline. A
    # require originating from one of these means the client — and therefore the
    # secret key — is reachable from the browser side of the app.
    BROWSER_REACHABLE = %r{(?:\A|/)app/(?:assets|javascript)(?:/|\z)}

    # The gem's own browser-JS directory, which hosts are *told* to put on the
    # asset load path (see INSTALL.md, importmap setup). It contains only
    # Stimulus glue — no Ruby, no credentials — so it is explicitly allowed.
    ALLOWED_ASSET_SUBPATH = File.join(GEM_ROOT, "app", "javascript")

    module_function

    # Rejects a +require "wavebird"+ that originates from a host's asset-pipeline
    # or browser-bundle tree.
    #
    # Frames inside this gem are skipped (the engine's own controllers and
    # helpers legitimately live under +app/+), as are Ruby/RubyGems/Bundler
    # internals, so the first *host* frame is what gets judged.
    #
    # @param locations [Array<Thread::Backtrace::Location>] injectable for tests
    # @param gem_root [String] injectable for tests
    # @return [void]
    # @raise [ConfigurationError] when required from a browser-reachable path
    def assert_server_side_require!(locations = caller_locations, gem_root: GEM_ROOT)
      offender = locations.find { |location| browser_reachable_frame?(location, gem_root) }
      return if offender.nil?

      raise ConfigurationError, browser_require_message(offender.absolute_path || offender.path)
    end

    # True when a backtrace frame belongs to a host's asset-pipeline / bundled
    # tree — i.e. not the gem itself and not a Ruby/RubyGems/Bundler internal.
    # @api private
    def browser_reachable_frame?(location, gem_root)
      path = location.absolute_path || location.path
      return false if path.nil?
      return false if inside?(path, gem_root) || ruby_internal?(path)

      path.match?(BROWSER_REACHABLE)
    end

    # Rejects asset load paths that would expose the gem's server-side Ruby.
    #
    # The gem's +app/javascript+ directory is allowed (that is the documented
    # importmap setup); its +lib/+ tree and its root are not — serving those
    # would publish the client, and with it anything the host has configured.
    #
    # @param paths [Array<String, Pathname>] the host's asset load paths
    # @param gem_root [String] injectable for tests
    # @return [void]
    # @raise [ConfigurationError] when a path would expose the gem's Ruby
    def assert_assets_paths_safe!(paths, gem_root: GEM_ROOT)
      offender = Array(paths).find do |raw|
        path = File.expand_path(raw.to_s)
        next false if inside?(path, ALLOWED_ASSET_SUBPATH)

        exposes_ruby?(path, gem_root)
      end
      return if offender.nil?

      raise ConfigurationError, assets_path_message(offender)
    end

    # Railtie initializer body: scans the host application's asset load paths
    # when it has an asset pipeline at all. The gem depends on neither sprockets
    # nor propshaft, so an app without one is simply left alone.
    #
    # @param app [Rails::Application]
    # @return [void]
    def run(app)
      assets = app.config.respond_to?(:assets) ? app.config.assets : nil
      paths = assets.respond_to?(:paths) ? assets.paths : nil
      return if paths.nil?

      assert_assets_paths_safe!(paths)
    end

    # @api private
    def inside?(path, root)
      path == root || path.start_with?("#{root}/")
    end

    # Ruby stdlib / RubyGems / Bundler frames, which sit between the host's
    # require and this file and must not be judged.
    # @api private
    def ruby_internal?(path)
      path.include?("/rubygems/") || path.include?("/bundler/") ||
        path.start_with?("<") || path.include?("/ruby/")
    end

    # A path exposes the gem's Ruby when it is the gem root itself, or contains
    # (or sits inside) the gem's +lib/+ tree.
    # @api private
    def exposes_ruby?(path, gem_root)
      lib = File.join(gem_root, "lib")
      path == gem_root || inside?(path, lib) || inside?(lib, path)
    end

    # @api private
    def browser_require_message(path)
      "Wavebird was required from #{path}, which is part of the asset pipeline / browser bundle. " \
        "The wavebird client holds your secret key and must stay server-side only: require it from " \
        "app/, config/ or lib/ instead (build prompt §4). If this path is a false positive, require " \
        "\"wavebird\" from a server-side file and reference it from there."
    end

    # @api private
    def assets_path_message(path)
      "Wavebird's server-side Ruby is on the asset load path (#{path}), which would publish the " \
        "client — and any credentials it is configured with — as a static asset. Remove that path; " \
        "only #{ALLOWED_ASSET_SUBPATH} (the browser Stimulus glue) belongs there. See INSTALL.md."
    end
  end
end
