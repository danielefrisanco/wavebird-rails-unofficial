# frozen_string_literal: true

RSpec.describe Wavebird::BootCheck do
  let(:gem_root) { "/srv/gems/wavebird-rails" }

  # A stand-in for Thread::Backtrace::Location: the checks only read
  # #absolute_path and #path.
  def location(absolute_path, path: absolute_path)
    instance_double(Thread::Backtrace::Location, absolute_path: absolute_path, path: path)
  end

  describe ".assert_server_side_require!" do
    it "raises when required from a host's app/javascript tree" do
      frames = [location("/app/myapp/app/javascript/entrypoint.rb")]

      expect { described_class.assert_server_side_require!(frames, gem_root: gem_root) }
        .to raise_error(Wavebird::ConfigurationError, %r{app/javascript/entrypoint\.rb})
    end

    it "raises when required from a host's app/assets tree" do
      frames = [location("/app/myapp/app/assets/config.rb")]

      expect { described_class.assert_server_side_require!(frames, gem_root: gem_root) }
        .to raise_error(Wavebird::ConfigurationError, /asset pipeline/)
    end

    it "explains that the secret key must stay server-side" do
      frames = [location("/app/myapp/app/javascript/entrypoint.rb")]

      expect { described_class.assert_server_side_require!(frames, gem_root: gem_root) }
        .to raise_error(/secret key and must stay server-side/)
    end

    it "allows a require from a server-side host file" do
      frames = [location("/app/myapp/app/models/chat.rb"), location("/app/myapp/config/application.rb")]

      expect { described_class.assert_server_side_require!(frames, gem_root: gem_root) }.not_to raise_error
    end

    it "ignores the gem's own app/javascript frames" do
      # The gem ships browser JS under its own app/javascript; loading the gem
      # must never trip on itself.
      frames = [location("#{gem_root}/app/javascript/wavebird/index.rb")]

      expect { described_class.assert_server_side_require!(frames, gem_root: gem_root) }.not_to raise_error
    end

    it "ignores Ruby, RubyGems and Bundler internal frames" do
      frames = [
        location("/usr/lib/ruby/3.4.0/app/javascript/weird.rb"),
        location("/gems/bundler/lib/bundler/app/assets/x.rb"),
        location("/gems/rubygems/core_ext/app/assets/y.rb")
      ]

      expect { described_class.assert_server_side_require!(frames, gem_root: gem_root) }.not_to raise_error
    end

    it "skips frames with no path at all" do
      frames = [location(nil, path: nil), location("/app/myapp/app/models/chat.rb")]

      expect { described_class.assert_server_side_require!(frames, gem_root: gem_root) }.not_to raise_error
    end

    it "falls back to #path when #absolute_path is nil (eval'd frames)" do
      frames = [location(nil, path: "/app/myapp/app/javascript/entrypoint.rb")]

      expect { described_class.assert_server_side_require!(frames, gem_root: gem_root) }
        .to raise_error(Wavebird::ConfigurationError)
    end

    it "defaults to the real caller stack and passes from the spec suite" do
      expect { described_class.assert_server_side_require! }.not_to raise_error
    end
  end

  describe ".assert_assets_paths_safe!" do
    it "raises when the gem's lib tree is on the asset load path" do
      paths = ["#{gem_root}/lib"]

      expect { described_class.assert_assets_paths_safe!(paths, gem_root: gem_root) }
        .to raise_error(Wavebird::ConfigurationError, /server-side Ruby is on the asset load path/)
    end

    it "raises when the gem root itself is on the asset load path" do
      expect { described_class.assert_assets_paths_safe!([gem_root], gem_root: gem_root) }
        .to raise_error(Wavebird::ConfigurationError)
    end

    it "raises when an ancestor directory containing the gem's lib is registered" do
      # Serving a parent directory would publish lib/ underneath it.
      expect { described_class.assert_assets_paths_safe!(["/srv/gems"], gem_root: gem_root) }
        .to raise_error(Wavebird::ConfigurationError)
    end

    it "allows the gem's own app/javascript (the documented importmap setup)" do
      paths = ["#{described_class::GEM_ROOT}/app/javascript"]

      expect { described_class.assert_assets_paths_safe!(paths) }.not_to raise_error
    end

    it "allows ordinary host asset paths" do
      paths = ["/app/myapp/app/assets/stylesheets", "/app/myapp/app/javascript"]

      expect { described_class.assert_assets_paths_safe!(paths, gem_root: gem_root) }.not_to raise_error
    end

    it "accepts Pathname entries" do
      paths = [Pathname.new("#{gem_root}/lib")]

      expect { described_class.assert_assets_paths_safe!(paths, gem_root: gem_root) }
        .to raise_error(Wavebird::ConfigurationError)
    end

    it "tolerates a nil path list" do
      expect { described_class.assert_assets_paths_safe!(nil, gem_root: gem_root) }.not_to raise_error
    end
  end

  describe ".run" do
    # Minimal stand-ins for the Rails application config chain.
    def app_with(assets)
      config = double("config") # rubocop:disable RSpec/VerifiedDoubles
      allow(config).to receive(:respond_to?).with(:assets).and_return(!assets.nil?)
      allow(config).to receive(:assets).and_return(assets)
      instance_double(Rails::Application, config: config)
    end

    it "scans the application's asset paths when it has an asset pipeline" do
      assets = double("assets") # rubocop:disable RSpec/VerifiedDoubles
      allow(assets).to receive_messages(respond_to?: true, paths: ["#{described_class::GEM_ROOT}/lib"])

      expect { described_class.run(app_with(assets)) }
        .to raise_error(Wavebird::ConfigurationError, /asset load path/)
    end

    it "passes for an application whose asset paths are safe" do
      assets = double("assets") # rubocop:disable RSpec/VerifiedDoubles
      allow(assets).to receive_messages(respond_to?: true, paths: ["/app/myapp/app/assets/images"])

      expect { described_class.run(app_with(assets)) }.not_to raise_error
    end

    it "no-ops for an application with no asset pipeline (sprockets/propshaft absent)" do
      expect { described_class.run(app_with(nil)) }.not_to raise_error
    end

    it "no-ops when the asset config exposes no paths" do
      assets = double("assets") # rubocop:disable RSpec/VerifiedDoubles
      allow(assets).to receive(:respond_to?).with(:paths).and_return(false)

      expect { described_class.run(app_with(assets)) }.not_to raise_error
    end
  end
end
