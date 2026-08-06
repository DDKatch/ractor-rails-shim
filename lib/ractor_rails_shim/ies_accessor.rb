# frozen_string_literal: true

# IESAccessor (Issue #45): generates reader/writer methods via the 3-tier
# IES lookup pattern. Extracts the repeated accessor boilerplate from
# patches/active_support.rb (20+ accessor patches that all follow the
# same shape).
#
# The generated methods use StorageStrategy for the actual lookup/store,
# so they inherit both Ractor-mode and Thread-mode behavior without
# duplicating the lookup logic.
#
# Usage:
#   RactorRailsShim::IESAccessor.define_accessor(
#     ActiveSupport::Inflector::Inflections,
#     :instance,
#     :ractor_rails_shim_inflections_en
#   )
#
# This generates a reader (`instance`) and writer (`instance=`) on the
# target class that do the 3-tier lookup:
#   1. IES (per-Ractor IsolatedExecutionState)
#   2. SHAREABLE_FALLBACK (frozen config captured at prepare time)
#   3. main-Ractor default (CLASS_ATTR_VALUES or nil)

module RactorRailsShim
  module IESAccessor
    # Generate a reader method on `target` that does the 3-tier lookup.
    # `target` is a Class or Module. `attr_name` is the method name (Symbol).
    # `ies_key` is the storage key (Symbol).
    def self.define_reader(target, attr_name, ies_key)
      key_str = ies_key.inspect
      target.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        def #{attr_name}
          strategy = RactorRailsShim.storage_strategy
          strategy.lookup(self, #{key_str}, nil)
        end
      RUBY
    end

    # Generate a writer method on `target` that stores via storage_strategy.
    def self.define_writer(target, attr_name, ies_key)
      key_str = ies_key.inspect
      target.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        def #{attr_name}=(val)
          strategy = RactorRailsShim.storage_strategy
          strategy.store(self, #{key_str}, val)
          val
        end
      RUBY
    end

    # Generate both reader and writer on `target`.
    def self.define_accessor(target, attr_name, ies_key)
      define_reader(target, attr_name, ies_key)
      define_writer(target, attr_name, ies_key)
    end
  end
end
