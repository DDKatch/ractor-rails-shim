# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ractor_rails_shim/patches"

# Pins the Issue #36b contract: AppShareabilizer OWNS its SHAREABLE_APP
# stash as a constant on the role module, NOT on the RactorRailsShim
# facade. The role's output state is no longer on the facade.
class AppShareabilizerOwnershipSpec < Minitest::Spec
  AS = RactorRailsShim::AppShareabilizer

  it "stash! defines SHAREABLE_APP on AppShareabilizer, not on the facade" do
    AS.reset_stashed!
    app = Object.new
    AS.stash!(app)
    assert AS.const_defined?(:SHAREABLE_APP, false),
           "SHAREABLE_APP should be defined on AppShareabilizer"
    assert_same app, AS::SHAREABLE_APP
    refute RactorRailsShim.const_defined?(:SHAREABLE_APP, false),
           "facade must not hold SHAREABLE_APP (Issue #36b)"
  ensure
    AS.reset_stashed!
  end

  it "stash! is idempotent (first writer wins on AppShareabilizer)" do
    AS.reset_stashed!
    app1 = Object.new
    app2 = Object.new
    AS.stash!(app1)
    AS.stash!(app2)
    assert_same app1, AS::SHAREABLE_APP
  ensure
    AS.reset_stashed!
  end

  it "reset_stashed! clears SHAREABLE_APP from AppShareabilizer" do
    AS.reset_stashed!
    AS.stash!(Object.new)
    assert AS.const_defined?(:SHAREABLE_APP, false)
    AS.reset_stashed!
    refute AS.const_defined?(:SHAREABLE_APP, false)
  end
end