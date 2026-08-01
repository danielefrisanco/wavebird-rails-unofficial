# frozen_string_literal: true

# Serves ES modules from their real locations — the gem's own app/javascript and
# the stimulus/turbo gems — rather than copying build artifacts into public/.
# Keeps the importmap honest: these are the exact files a host would load, with
# nothing vendored, symlinked or machine-specific.
class JsServer
  ROOTS = {
    "wavebird-js" => -> { Wavebird::Engine.root.join("app/javascript") },
    "stimulus-js" => -> { Stimulus::Engine.root.join("app/assets/javascripts") },
    "turbo-js" => -> { Turbo::Engine.root.join("app/assets/javascripts") }
  }.freeze

  def self.call(env)
    new(env).call
  end

  def initialize(env)
    @path = ActionDispatch::Request.new(env).path_info.delete_prefix("/")
  end

  def call
    file = resolve
    return not_found unless file

    [200, { "content-type" => "text/javascript" }, [file.read]]
  end

  private

  # Resolves the request onto a file under one of the known roots, refusing
  # anything that escapes it (`..` traversal).
  def resolve
    prefix, _, relative = @path.partition("/")
    root = ROOTS[prefix]&.call
    return if root.nil?

    file = root.join(relative).expand_path
    file if file.to_s.start_with?(root.to_s) && file.file?
  end

  def not_found
    [404, { "content-type" => "text/plain" }, ["not found"]]
  end
end
