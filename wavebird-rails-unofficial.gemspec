# frozen_string_literal: true

require_relative "lib/wavebird/version"

Gem::Specification.new do |spec|
  spec.name = "wavebird-rails-unofficial"
  spec.version = Wavebird::VERSION
  spec.authors = ["Daniele Frisanco"]
  spec.email = ["daniele.frisanco@gmail.com"]

  spec.summary = "Unofficial Rails client and Hotwire integration for the wavebird Compute Sponsoring API."
  spec.description = <<~DESC.strip
    Unofficial and unaffiliated: an independent port, not built, endorsed or
    supported by wavebird. Their own docs at https://wavebird.ai/api are the
    source of truth.

    Server-side API client plus Rails integration (engine routes, controller,
    slot view helpers, Stimulus glue for wavebird's hosted renderer, and an
    optional async delivery mode over Turbo Streams) for wavebird
    (https://wavebird.ai). A Ruby/Rails port of the original public wavebird
    TypeScript SDK (https://github.com/wavebird-ai/wavebird).
  DESC
  spec.homepage = "https://github.com/danielefrisanco/wavebird-rails-unofficial"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  # Distinct values on purpose: rubygems.org shows only the first of any set of
  # identical URIs, so pointing homepage_uri and source_code_uri at the same
  # string silently drops one of the links.
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.glob(
    # lib/**/*.tt carries the install generator's templates, which are not .rb on
    # purpose — Thor strips the suffix, and a loadable .rb under lib/ would be a
    # config file that runs itself if anything ever eager-loaded the directory.
    %w[lib/**/*.rb lib/**/*.tt app/**/* config/**/*.rb examples/**/*
       LICENSE.txt CHANGELOG.md README.md INSTALL.md]
  ).select { |f| File.file?(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "faraday", "~> 2.0"
  spec.add_dependency "railties", ">= 7.1", "< 9"
end
