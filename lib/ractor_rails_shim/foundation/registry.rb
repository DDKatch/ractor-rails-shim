# frozen_string_literal: true

# Registry: the canonical home for the shared registries that every role
# object reads/writes (Issue #25, POODR §1 SRP + §2 Dependencies).
#
# Issue #35 (Round 4): Registry OWNS the nine registries as instance
# variables. The facade constants in patches/core.rb are aliases that
# delegate to Registry. Reassignment of the frozen (shareable) registries
# goes through Registry.reassign_* so the facade alias tracks the new
# value without a $VERBOSE-suppressed const_set on the facade.
#
# Types:
#   - Mutable Array: class_attributes, shareable_constants, shareable_class_ivars
#   - Mutable Hash:  mattr_defaults, class_attr_values, shareable_mattr_defaults
#   - Frozen (Ractor.make_shareable): abstract_registry, view_context_registry,
#     shareable_fallback
#
# The frozen registries start as empty shareable Hashes and are swapped
# (via reassign_*) at prepare_for_ractors! / make_app_shareable! time with
# the populated, frozen, shareable versions. The mutable registries are
# appended at boot (main Ractor) and read at request time (worker Ractors).

module RactorRailsShim
  module Registry
    @class_attributes = []
    @mattr_defaults = {}
    @class_attr_values = {}
    @shareable_mattr_defaults = {}
    @shareable_constants = []
    @shareable_class_ivars = []
    @abstract_registry = Ractor.make_shareable({})
    @view_context_registry = Ractor.make_shareable({})
    @shareable_fallback = Ractor.make_shareable({})

    class << self
      attr_reader :class_attributes, :mattr_defaults, :class_attr_values,
                  :shareable_mattr_defaults, :shareable_constants,
                  :shareable_class_ivars, :abstract_registry,
                  :view_context_registry, :shareable_fallback

      # Swap the frozen (shareable) registries. The value MUST already be
      # frozen + Ractor.make_shareable. Each reassign_* updates the
      # instance variable; the facade alias (defined in patches/core.rb)
      # re-reads it on every access, so the alias tracks the new value
      # without a const_set on the facade singleton.
      def reassign_shareable_fallback(value)
        @shareable_fallback = value
      end

      def reassign_shareable_mattr_defaults(value)
        @shareable_mattr_defaults = value
      end

      def reassign_abstract_registry(value)
        @abstract_registry = value
      end

      def reassign_view_context_registry(value)
        @view_context_registry = value
      end

      # Test seam: reset all nine registries to their boot defaults. Used
      # by specs that mutate the registries and need a clean slate.
      def reset_all
        @class_attributes = []
        @mattr_defaults = {}
        @class_attr_values = {}
        @shareable_mattr_defaults = {}
        @shareable_constants = []
        @shareable_class_ivars = []
        @abstract_registry = Ractor.make_shareable({})
        @view_context_registry = Ractor.make_shareable({})
        @shareable_fallback = Ractor.make_shareable({})
      end
    end
  end
end