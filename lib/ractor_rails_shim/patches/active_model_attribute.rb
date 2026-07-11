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
        ActiveSupport::IsolatedExecutionState[key] ||=
          ::ActiveModel::AttributeSet.new({}).tap do |attribute_set|
            apply_pending_attribute_modifications(attribute_set)
          end
      end

      def attribute_types # :nodoc:
        key = :"rrs_attribute_types_#{object_id}"
        ActiveSupport::IsolatedExecutionState[key] ||= begin
          types = _default_attributes.cast_types
          types.default = ::ActiveModel::Type.default_value
          types
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
        ActiveSupport::IsolatedExecutionState[key] ||= begin
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
end
