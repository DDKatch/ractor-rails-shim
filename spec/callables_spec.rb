# frozen_string_literal: true

require "minitest/autorun"
require "ractor_rails_shim/patches/callables"

# Pins the extraction of the callable/lock-replacement object model from
# make_shareable.rb into its own file (patches/callables.rb). The classes must
# be accessible on RactorRailsShim's singleton class (same access path the
# rest of the codebase and specs use) and individually shareable when frozen.
class CallablesExtractionSpec < Minitest::Spec
  SC = RactorRailsShim.singleton_class

  # Every class that was in make_shareable.rb's module_eval block must now be
  # defined from callables.rb. If the extraction drops one, this catches it.
  [:NoOpProc, :Callable, :CallableConst, :DeviseMappingSnapshot,
   :NoOpLock, :NoOpLogDev].each do |cls|
    it "#{cls} is defined on RactorRailsShim singleton class" do
      assert SC.const_defined?(cls, false),
             "#{cls} should be defined on RactorRailsShim singleton class"
    end
  end

  it "_devise_mapping_snapshot helper is defined on RactorRailsShim" do
    assert RactorRailsShim.respond_to?(:_devise_mapping_snapshot, false),
           "_devise_mapping_snapshot must remain accessible"
  end

  # Smoke-test: instances are shareable after make_shareable (the whole point
  # of these classes is to be Ractor-safe replacements for unshareable Procs/
  # locks/IOs).
  it "NoOpProc and NoOpLock instances are Ractor-shareable after make_shareable" do
    np = SC.const_get(:NoOpProc).new
    lk = SC.const_get(:NoOpLock).new
    Ractor.make_shareable(np); Ractor.make_shareable(lk)
    assert Ractor.shareable?(np)
    assert Ractor.shareable?(lk)
  end
end