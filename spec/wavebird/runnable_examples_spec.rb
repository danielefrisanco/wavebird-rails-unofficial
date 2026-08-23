# frozen_string_literal: true

require "erb"

# `examples/chat_plain.rb` and `examples/chat_hotwire.rb` are single-file Rails
# apps: `ruby examples/chat_plain.rb` boots a real server. They are the first
# thing a new user runs, and until this spec they were the least tested code in
# the repo — verified by hand once, by nothing repeatable.
#
# They cannot be `require`d here. Each defines a `Rails::Application`, and only
# one may exist per process, so anything that *boots* them has to shell out
# (that is the system-suite half of this, plan v2 item G3-G4). Everything below
# reads them as text or as an AST instead, which is enough to catch the two bugs
# that actually happened while writing them.
RUNNABLE_EXAMPLES = Dir.glob(File.expand_path("../../examples/*.rb", __dir__)).freeze

RSpec.describe "examples/*.rb (runnable single-file apps)", :aggregate_failures do # rubocop:disable RSpec/DescribeClass
  # The evaluated value of the file's TEMPLATE constant, without loading it.
  # Taken from the AST rather than by regex so it is the string the interpreter
  # would build, interpolation and all -- which is the whole point below.
  def template_literal(path)
    found = nil
    walk = lambda do |node|
      return unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

      found = node.children.last if node.type == :CDECL && node.children.first == :TEMPLATE
      node.children.each { |child| walk.call(child) }
    end
    walk.call(RubyVM::AbstractSyntaxTree.parse_file(path))
    found
  end

  it "finds both runnable examples" do
    # Guards against the glob silently matching nothing and every example below
    # passing vacuously -- the failure mode that let the first version of
    # docs_turn_body_contract_spec.rb pass with the code it guarded deleted.
    expect(RUNNABLE_EXAMPLES.map { |path| File.basename(path) })
      .to contain_exactly("chat_hotwire.rb", "chat_plain.rb", "chat_react.rb")
  end

  RUNNABLE_EXAMPLES.each do |path|
    describe File.basename(path) do
      let(:source) { File.read(path) }
      let(:name) { File.basename(path) }

      # G1. Catches the class of error that cost a debugging round during
      # authoring. Cheap, and it runs before anything else can be trusted.
      it "parses as valid Ruby" do
        expect { RubyVM::AbstractSyntaxTree.parse_file(path) }.not_to raise_error
      end

      it "holds its page in a TEMPLATE string literal" do
        expect(template_literal(path)&.type).to eq(:STR)
      end

      # The load-bearing invariant. `<<~ERB` (unquoted) interpolates, and the
      # templates contain `<%# ... %>` ERB comments; a `{` after one of those
      # `#` characters turns the comment into Ruby interpolation. Asserting the
      # quotes directly is the only check here that names the actual rule --
      # everything else observes a consequence of it.
      it "quotes the heredoc delimiter so the template cannot interpolate" do
        expect(source).to include("TEMPLATE = <<~'ERB'")
      end

      # ...and the consequence, asserted independently, because a future
      # template could reintroduce the bug with a different delimiter spelling.
      #
      # Why not `ERB.new(t).src` compilation, which plan v2 proposed for this:
      # it does not work. The historical bug turned `<%#{" "}comment %>` into
      # `<% comment %>` -- an *open tag* whose body is English prose, and prose
      # like "This is a comment" happens to be valid Ruby (method calls), so the
      # generated source compiles cleanly and the bug walks straight through.
      # Comparing the comments in the file against the comments that survive
      # into the string is sensitive to it: an eaten `#` changes the count.
      it "preserves every ERB comment from the heredoc into the template" do
        # Only the heredoc body -- the file also explains this rule in Ruby
        # comments, and counting those would compare two different things.
        raw = source[/^TEMPLATE = <<~'?ERB'?$\n(.*?)^ERB$/m, 1]
        expect(raw).not_to be_nil, "could not find the TEMPLATE heredoc in #{name}"

        in_heredoc = raw.scan("<%#").length
        in_template = template_literal(path).children.first.scan("<%#").length

        expect(in_heredoc).to be_positive # or this example proves nothing
        expect(in_template).to eq(in_heredoc)
      end

      # G2. Not sensitive to the interpolation bug (see above), but it does
      # catch an unclosed or malformed tag, which is the other way to ship a
      # file that parses and a page that does not render.
      it "compiles as an ERB template, into Ruby that itself compiles" do
        erb_source = ERB.new(template_literal(path).children.first).src

        expect { RubyVM::InstructionSequence.compile(erb_source) }.not_to raise_error
      end
    end
  end
end
