# frozen_string_literal: true

# Registry: the canonical home for the shared registries that every role
# object reads/writes (Issue #25, POODR §1 SRP + §2 Dependencies).
#
# The nine registries formerly lived as constants on the RactorRailsShim
# facade (patches/core.rb:33-84). Every role object reached them through
# the facade global. Moving them here makes the registries the single
# source of truth — the facade constants become aliases for backward
# compatibility (removed in #31).
#
# Readers delegate to the current facade constants so that
# `reassign_shareable_const` (which replaces the constant via
# `const_set`) is transparent — Registry always returns the live object.
#
# Types:
#   - Mutable Array: class_attributes, shareable_constants, shareable_class_ivars
#   - Mutable Hash:  mattr_defaults, class_attr_values, shareable_mattr_defaults
#   - Frozen (Ractor.make_shareable): abstract_registry, view_context_registry,
#     shareable_fallback

module RactorRailsShim
  module Registry
    def self.class_attributes
      RactorRailsShim::CLASS_ATTRIBUTES
    end

    def self.mattr_defaults
      RactorRailsShim::MATTR_DEFAULTS
    end

    def self.class_attr_values
      RactorRailsShim::CLASS_ATTR_VALUES
    end

    def self.shareable_mattr_defaults
      RactorRailsShim::SHAREABLE_MATTR_DEFAULTS
    end

    def self.shareable_constants
      RactorRailsShim::SHAREABLE_CONSTANTS
    end

    def self.shareable_class_ivars
      RactorRailsShim::SHAREABLE_CLASS_IVARS
    end

    def self.abstract_registry
      RactorRailsShim::ABSTRACT_REGISTRY
    end

    def self.view_context_registry
      RactorRailsShim::VIEW_CONTEXT_REGISTRY
    end

    def self.shareable_fallback
      RactorRailsShim::SHAREABLE_FALLBACK
    end
  end
end
