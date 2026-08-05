# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ractor_rails_shim/patches"

# Pins the Issue #38 contract: the facade make_app_shareable! requires
# an explicit app argument (no default), matching the role's contract
# (AppShareabilizer.make_shareable!).
class MakeAppShareableNoDefaultSpec < Minitest::Spec
  it "make_app_shareable! requires an explicit app argument (no default)" do
    assert_raises ArgumentError do
      RactorRailsShim.make_app_shareable!
    end
  end
end