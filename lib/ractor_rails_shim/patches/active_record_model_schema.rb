# frozen_string_literal: true

# ActiveRecord caches a number of values in class-level ivars via `@ivar ||=`
# (ModelSchema::ClassMethods). Several of these hold UNshareable values
# (AttributeSet::Builder, AttributeSet::YAMLEncoder, Hashes of Attribute
# objects) or take arguments, so neither pre-warming nor `Ractor.make_shareable`
# makes them safe for worker Ractors: a worker reading the class ivar hits
# Ractor::IsolationError (unshareable value) and writing it (the `||=`) hits
# "can not set instance variables of classes/modules by non-main Ractors".
#
# We redirect these specific caches to per-Ractor storage
# (ActiveSupport::IsolatedExecutionState), keyed by the class. Each worker
# Ractor computes and keeps its OWN copy — it never touches the shared class
# ivar, so there is no cross-boundary (unshareable) value and no class-ivar
# write. The values are deterministic from the schema/connection, so per-Ractor
# caching is behavior-preserving. In the main Ractor this behaves identically
# (compute once, cache).

module RactorRailsShim
  module ActiveRecordModelSchemaPatch
    def self.prepended(base)
      base.prepend(InstanceMethods)
    end

    module InstanceMethods
      def _returning_columns_for_insert(connection) # :nodoc:
        key = :"rrs_returning_cols_#{object_id}"
        ActiveSupport::IsolatedExecutionState[key] ||= begin
          auto_populated_columns = columns.filter_map do |c|
            c.name if connection.return_value_after_insert?(c)
          end

          auto_populated_columns.empty? ? Array(primary_key) : auto_populated_columns
        end
      end

      def attributes_builder # :nodoc:
        key = :"rrs_attributes_builder_#{object_id}"
        ActiveSupport::IsolatedExecutionState[key] ||= begin
          defaults = _default_attributes.except(*(column_names - [primary_key]))
          ::ActiveModel::AttributeSet::Builder.new(attribute_types, defaults)
        end
      end

      def column_defaults # :nodoc:
        key = :"rrs_column_defaults_#{object_id}"
        ActiveSupport::IsolatedExecutionState[key] ||=
          _default_attributes.deep_dup.to_hash.freeze
      end

      def yaml_encoder # :nodoc:
        key = :"rrs_yaml_encoder_#{object_id}"
        ActiveSupport::IsolatedExecutionState[key] ||=
          ::ActiveModel::AttributeSet::YAMLEncoder.new(attribute_types)
      end
    end
  end
end
