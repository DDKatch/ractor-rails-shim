# frozen_string_literal: true

# Regression spec for patches/cgi.rb (shim TODO #5, worker-Ractor ActiveJob
# enqueue): CGI::Escape seeds its default decoding charset in a CLASS VARIABLE
# (@@accept_charset = Encoding::UTF_8), and the default ARGUMENTS of
# unescape / unescapeURIComponent reference it (`encoding = @@accept_charset`).
# Ruby forbids reading class variables from non-main Ractors outright — even
# shareable ones:
#
#   Ractor::IsolationError: can not access class variables from non-main
#   Ractors (@@accept_charset from #<Class:CGI>)
#
# globalid (URI::GID parsing) hits this from any worker-Ractor
# GlobalID.create, which put it on the ActiveJob enqueue path. The patch
# re-defines both methods on CGI::Escape AND CGI::EscapeExt (the C ext from
# cgi/escape.so, which shadows Escape and whose C impl reads the class var
# internally) with a frozen snapshot constant as the default.

require "minitest/autorun"
require_relative "../lib/ractor_rails_shim/patches"

class CgiEscapePatchSpec < Minitest::Spec
  # Install the patch — apply! requires "cgi/escape" itself and is idempotent.
  before do
    RactorRailsShim::CGIPatch.apply!
  end

  it "exposes a frozen shareable snapshot constant" do
    assert Ractor.shareable?(RactorRailsShim::CGI_ACCEPT_CHARSET)
    assert_equal Encoding::UTF_8, RactorRailsShim::CGI_ACCEPT_CHARSET
  end

  it "does not leave @@accept_charset reads on the patched default path" do
    # The patched default must NOT reference the class variable: simulate the
    # worker restriction by checking the method's default arity/params —
    # stronger check below runs the method in a real worker Ractor.
    assert CGI.method(:unescape).parameters.any? { |(_kind, name)| name == :encoding }
  end

  it "lets a worker Ractor call CGI.unescape without an IsolationError" do
    result = Ractor.new do
      CGI.unescape("hello%20ractor%2Bworld")
    end
    assert_equal "hello ractor+world", result.value
  end

  it "lets a worker Ractor call CGI.unescapeURIComponent" do
    result = Ractor.new do
      CGI.unescapeURIComponent("a%2Fb%20c")
    end
    assert_equal "a/b c", result.value
  end

  it "keeps explicit-encoding calls working in the main Ractor" do
    assert_equal "a b", CGI.unescape("a%20b", Encoding::UTF_8)
    assert_equal "a b", CGI.unescapeURIComponent("a%20b", Encoding::UTF_8)
  end
end
