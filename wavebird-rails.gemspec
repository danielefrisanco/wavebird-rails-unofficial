# frozen_string_literal: true

require_relative "lib/wavebird/version"

Gem::Specification.new do |spec|
  spec.name = "wavebird-rails"
  spec.version = Wavebird::VERSION
  spec.authors = ["Daniele Frisanco"]
  spec.email = ["daniele.frisanco@gmail.com"]

  spec.summary = "Rails client and Hotwire integration for the wavebird Compute Sponsoring API."
  spec.description = <<~DESC.strip
    Server-side API client plus Rails integration (engine routes, controller,
    Turbo Frame helpers, Stimulus glue for wavebird's hosted renderer) for
    wavebird (https://wavebird.ai). A Ruby/Rails port of the original public
    wavebird TypeScript SDK (https://github.com/wavebird-ai/wavebird).
  DESC
  spec.homepage = "https://github.com/danielefrisanco/wavebird-rails"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.glob(
    %w[lib/**/*.rb app/**/* config/**/*.rb LICENSE.txt CHANGELOG.md README.md INSTALL.md]
  ).select { |f| File.file?(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "faraday", "~> 2.0"
  spec.add_dependency "railties", ">= 7.1", "< 9"
end
