# frozen_string_literal: true

# Patch two ActiveModel/ActiveRecord behaviors so worker Ractors (under a
# frozen `:ractor` shared graph) can build and persist records.
#
# 1. Attribute#dup_or_share (writes): see ActiveModelAttributePatch below.
# 2. AttributeRegistration class caches (reads): `@attribute_types`,
#    `@default_attributes`, etc. hold ActiveModel::Type instances, which are
#    NOT Ractor-shareable. Under `:ractor` the shim freezes the graph, so those
#    class-ivar values become unshareable; a worker reading them raises
#    `Ractor::IsolationError: can not get unshareable values from instance
#    variables ... (@attribute_types from Post)`, and a worker writing them
#    (the `||=` memoization) raises `can not set instance variables ...`.
#
#    Fix: serve these caches from per-Ractor storage (ActiveSupport::
#    IsolatedExecutionState), keyed by the class. Each worker Ractor computes
#    and keeps its OWN copy — it never touches the shared class ivar, so there
#    is no cross-boundary (unshareable) value and no class-ivar write. In the
#    main Ractor this behaves identically to the original (compute once, cache).
#    The values are deterministic from the schema, so per-Ractor caching is
#    behavior-preserving.

module RactorRailsShim
  module ActiveModelAttributePatch
    def self.included(base)
      base.prepend(InstanceMethods)
    end

    module InstanceMethods
      def dup_or_share # :nodoc:
        if frozen?
          self.class.from_database(
            name,
            value_before_type_cast,
            type,
            defined?(@value) ? @value : nil
          )
        else
          super
        end
      end
    end
  end

  module ActiveModelAttributeRegistrationPatch
    def self.prepended(base)
      base.prepend(InstanceMethods)
    end

    module InstanceMethods
      def _default_attributes # :nodoc:
        key = :"rrs_default_attributes_#{object_id}"
        RactorRailsShim.storage[key] ||=
          ::ActiveModel::AttributeSet.new({}).tap do |attribute_set|
            apply_pending_attribute_modifications(attribute_set)
          end
      end

      def attribute_types # :nodoc:
        key = :"rrs_attribute_types_#{object_id}"
        RactorRailsShim.storage[key] ||= begin
          types = _default_attributes.cast_types
          types.default = ::ActiveModel::Type.default_value
          types
        end
      end

      # `reset_default_attributes!` (called by `reload_schema_from_cache` via
      # the Attributes → Timestamp → ModelSchema super chain) writes
      # `@default_attributes = nil` and `@attribute_types = nil` class ivars.
      # In a worker Ractor those writes raise Ractor::IsolationError. The
      # shim routes the *readers* above through IES, so in a worker we clear
      # the IES slots instead (the next read rebuilds lazily). In main we keep
      # the original class-ivar-clearing behavior.
      def reset_default_attributes!
        if Ractor.main?
          @default_attributes = nil
          @attribute_types = nil
        else
          RactorRailsShim.storage.delete(:"rrs_default_attributes_#{object_id}")
          RactorRailsShim.storage.delete(:"rrs_attribute_types_#{object_id}")
        end
      end
    end
  end

  module ActiveRecordAttributesPatch
    def self.prepended(base)
      base.prepend(InstanceMethods)
    end

    module InstanceMethods
      # ActiveRecord overrides _default_attributes (attributes.rb:253) with a
      # version that reads the @default_attributes class ivar and opens a
      # connection to build the AttributeSet. Same per-Ractor fix as above:
      # cache in IES so workers never read/write the shared class ivar.
      def _default_attributes # :nodoc:
        key = :"rrs_default_attributes_#{object_id}"
        RactorRailsShim.storage[key] ||= begin
          attributes_hash = with_connection do |connection|
            columns_hash.transform_values do |column|
              ::ActiveModel::Attribute.from_database(
                column.name, column.default, type_for_column(connection, column)
              )
            end
          end
          attribute_set = ::ActiveModel::AttributeSet.new(attributes_hash)
          apply_pending_attribute_modifications(attribute_set)
          attribute_set
        end
      end
    end
  end

  # `RactorRailsShim::Patches::ActiveModelAttribute` — the role object that
  # owns the install step for the three ActiveModel/ActiveRecord attribute
  # patches above (extracted from the facade god module in Step 22.2,
  # Issue #22; POODR §1 SRP).
  #
  # The three `prepend`/`include` calls live here; only their home changes
  # (they were inlined on the facade's `_install_active_model_attribute_
  # patch`). The facade method now delegates to `.install` until Issue #31.
  #
  # The idempotency flag (`@installed`) lives on this object, not on the
  # facade. The guard `return unless defined?(::ActiveModel::Attribute)` is
  # preserved — when ActiveModel is not loaded (e.g. the shim's own unit
  # specs), install is a no-op that still records `installed? = true` (it
  # ran to completion, the precondition just wasn't met).
  module Patches
    module ActiveModelAttribute
      @installed = false
      @mutex = Mutex.new

      def self.install
        @mutex.synchronize do
          return true if @installed
          @installed = true
          next unless defined?(::ActiveModel::Attribute)
          ::ActiveModel::Attribute.include(::RactorRailsShim::ActiveModelAttributePatch)
          if defined?(::ActiveModel::AttributeRegistration) &&
             ::ActiveModel::AttributeRegistration.const_defined?(:ClassMethods)
            ::ActiveModel::AttributeRegistration::ClassMethods.prepend(
              ::RactorRailsShim::ActiveModelAttributeRegistrationPatch
            )
          end
          if defined?(::ActiveRecord::Attributes) &&
             ::ActiveRecord::Attributes.const_defined?(:ClassMethods)
            ::ActiveRecord::Attributes::ClassMethods.prepend(
              ::RactorRailsShim::ActiveRecordAttributesPatch
            )
          end
          if defined?(::ActiveRecord::ModelSchema) &&
             ::ActiveRecord::ModelSchema.const_defined?(:ClassMethods)
            ::ActiveRecord::ModelSchema::ClassMethods.prepend(
              ::RactorRailsShim::ActiveRecordModelSchemaPatch
            )
          end
        end
        true
      end

      def self.installed?
        @installed
      end

      def self.reset_installed_for_test!
        @mutex.synchronize { @installed = false }
      end
    end
  end
end
