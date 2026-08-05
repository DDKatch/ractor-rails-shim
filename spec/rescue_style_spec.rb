# frozen_string_literal: true

# Spec for Issue #3: normalize bare `rescue` (implicit StandardError) to
# explicit `rescue StandardError` in block-form rescues.
#
# Inline rescues (`expr rescue nil`) cannot specify an error class in Ruby
# syntax, so they are out of scope. Only block-form rescues (where `rescue`
# appears at the start of a line or after `;` in a single-line begin/end)
# are checked.

require "minitest/autorun"
require "pathname"

class RescueStyleSpec < Minitest::Spec
  LIB_DIR = Pathname.new(File.expand_path("../lib", __dir__))

  # Collect all block-form bare rescues in lib/. Returns an array of
  # "file:line: source" strings.
  def block_form_bare_rescues
    offenders = []
    Dir.glob(LIB_DIR.join("**", "*.rb")).sort.each do |path|
      File.readlines(path, chomp: true).each_with_index do |line, i|
        next if line.strip.start_with?("#")

        # Block bare rescue on its own line:  `rescue`  (nothing else)
        if line =~ /^\s*rescue\s*$/
          offenders << "#{path}:#{i + 1}: #{line.strip}"
        end

        # Block rescue with => but no class:  `rescue => e`
        if line =~ /^\s*rescue\s*=>\s*\w+/
          offenders << "#{path}:#{i + 1}: #{line.strip}"
        end

        # Single-line begin; ... rescue; ... — bare rescue after ;
        if line =~ /;\s*rescue\s*[;|]/
          offenders << "#{path}:#{i + 1}: #{line.strip}"
        end

        # Single-line begin; ... rescue => e; ...
        if line =~ /;\s*rescue\s*=>\s*\w+\s*[;|]/
          offenders << "#{path}:#{i + 1}: #{line.strip}"
        end
      end
    end
    offenders
  end

  it "has no block-form bare rescue without explicit StandardError" do
    offenders = block_form_bare_rescues
    assert offenders.empty?,
           "expected all block-form rescues to specify StandardError, " \
           "but found bare rescues:\n  #{offenders.join("\n  ")}"
  end
end
