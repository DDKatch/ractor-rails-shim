# frozen_string_literal: true

require "minitest/autorun"
require "active_support"
require "active_support/time"
require_relative "../lib/ractor_rails_shim/patches"

# Specs for the ActiveSupport::TimeZone lookup patch (core.rb
# `_install_time_zone_lookup_patch`).
#
# Upstream memoizes resolved zones into the class ivar @lazy_zones_map (a
# Concurrent::Map) — both reading it and writing it are forbidden in
# non-main Ractors (Ractor::IsolationError). The patch keeps the upstream
# body verbatim on main and gives workers a per-Ractor Hash cache from
# IsolatedExecutionState. The worker branch needs a live Ractor and is
# exercised by the kino (durations probe, row 131); these specs cover the
# MAIN-side semantics (verbatim upstream behavior).
class TimeZoneLookupSpec < Minitest::Spec
  before { RactorRailsShim::Patches::TimeZoneLookup.install }

  it "resolves a String zone on main (upstream behavior)" do
    zone = ActiveSupport::TimeZone["Europe/Berlin"]
    assert_instance_of ActiveSupport::TimeZone, zone
    assert_equal "Europe/Berlin", zone.name
  end

  it "returns the same instance for repeated lookups (class-ivar cache)" do
    assert_same ActiveSupport::TimeZone["Europe/Berlin"], ActiveSupport::TimeZone["Europe/Berlin"]
  end

  it "passes self through and rejects invalid arguments" do
    zone = ActiveSupport::TimeZone["Europe/Berlin"]
    assert_same zone, ActiveSupport::TimeZone[zone]
    error = assert_raises(ArgumentError) do
      ActiveSupport::TimeZone[Object.new]
    end
    assert_match(/invalid argument to TimeZone\[\]/, error.message)
  end
end
