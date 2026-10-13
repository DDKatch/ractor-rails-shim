# frozen_string_literal: true

require "minitest/autorun"
require "active_support"
require_relative "../lib/ractor_rails_shim/patches"

# Specs for the TZInfo::DataSource patch (core.rb
# `_install_tzinfo_data_source_patch`).
#
# Upstream memoizes the DataSource into the class variables @@instance /
# @@default_mutex — Ruby 4.0 forbids ANY class-variable access from a
# non-main Ractor. The patch keeps the upstream body verbatim on main and
# gives workers a per-Ractor DataSource from IsolatedExecutionState. The
# worker branch needs a live Ractor and is exercised by the kino
# (durations probe, row 131); these specs cover the MAIN-side semantics
# (verbatim upstream behavior).
class TzinfoDataSourceSpec < Minitest::Spec
  before { RactorRailsShim::Patches::TzinfoDataSource.install }

  it "returns a DataSource on main (upstream memoized instance)" do
    assert_kind_of TZInfo::DataSource, TZInfo::DataSource.get
  end

  it "returns the same instance across calls on main (class-variable cache)" do
    assert_same TZInfo::DataSource.get, TZInfo::DataSource.get
  end

  it "keeps set/get working on main (manual selection)" do
    original = TZInfo::DataSource.get
    # Setting the same source again must be a no-op of state, not an error.
    TZInfo::DataSource.set(original)
    assert_same original, TZInfo::DataSource.get
  end
end
