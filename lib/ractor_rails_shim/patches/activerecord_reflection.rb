# frozen_string_literal: true

# ActiveRecord reflections are frozen as part of the shareable app graph, but
# AR mutates them on first access (memoizing @foreign_key, @klass, @inverse_of,
# ...). On a worker Ractor that write raises FrozenError, so ANY association
# read (belongs_to / has_many / through) blows up. Rails has no hook to disable
# this memoization, and the reflection objects are shared (frozen) across
# Ractors, so we cannot simply skip freezing them.
#
# Fix: prepend overrides on the reflection classes that route each memoized
# value through a per-worker cache (Ractor.current) instead of writing an ivar
# on the frozen object. Each worker builds its own cache lazily, so the values
# are still computed once per worker and never mutate the shared object.

module RactorRailsShim
  module ReflectionMemoPatch
    # Per-worker memoization cache for reflection values. Defined as a plain
    # `def` (NOT define_method/block) so the method body is a shareable Method
    # — a block-based helper would be a Proc created in the main Ractor and
    # would raise "un-shareable Proc in a different Ractor" when called in a
    # worker.
    def rrs_refl_cache
      Ractor.current[:__rrs_refl_cache__] ||= {}
    end
  end

  module ReflectionAbstractPatch
    prepend ReflectionMemoPatch

    def class_name
      rrs_refl_cache[[object_id, :class_name]] ||= -(options[:class_name] || derive_class_name).to_s
    end

    def counter_cache_column
      rrs_refl_cache[[object_id, :counter_cache_column]] ||= begin
        counter_cache = options[:counter_cache]

        if belongs_to?
          if counter_cache
            counter_cache[:column] || -"#{active_record.name.demodulize.underscore.pluralize}_count"
          end
        else
          -((counter_cache && -counter_cache[:column]) || "#{name}_count")
        end
      end
    end

    def inverse_of
      return unless inverse_name

      rrs_refl_cache[[object_id, :inverse_of]] ||= klass._reflect_on_association inverse_name
    end

    # inverse_which_updates_counter_cache lazily memoizes
    # @inverse_which_updates_counter_cache / @inverse_which_updates_counter_cache_defined
    # on the (frozen, shared) reflection — which raises FrozenError in a worker
    # Ractor when a `dependent:` cascade touches a counter_cache (e.g. deleting a
    # parent whose child `belongs_to` it with `counter_cache: true`). Route the
    # memoization through the per-worker cache instead, mirroring the other
    # cache-backed reflection accessors above.
    def inverse_which_updates_counter_cache
      cache = rrs_refl_cache
      key = [object_id, :inverse_which_updates_counter_cache]
      return cache[key] if cache.key?(key)
      cache[key] =
        if counter_cache_column
          inverse_candidates = inverse_of ? [inverse_of] : klass.reflect_on_all_associations(:belongs_to)
          inverse_candidates.find do |inverse|
            inverse.counter_cache_column == counter_cache_column && (inverse.polymorphic? || inverse.klass == active_record)
          end
        end
    end
    alias inverse_updates_counter_cache? inverse_which_updates_counter_cache
  end

  module ReflectionMacroPatch
    prepend ReflectionMemoPatch

    def klass
      rrs_refl_cache[[object_id, :klass]] ||= _klass(class_name)
    end
  end

  module ReflectionAssociationPatch
    prepend ReflectionMemoPatch

    # check_validity! memoizes @validated by writing it on the (frozen, shared)
    # reflection — which raises FrozenError in a worker Ractor. Reimplement it
    # to store the validated flag in the per-worker cache instead. The body
    # mirrors Rails' (minus the @validated write) and only reads via the other
    # patched (cache-backed) reflection accessors, so it performs no ivar
    # writes on the frozen object.
    def check_validity!
      cache = rrs_refl_cache
      return if cache[[object_id, :validated]]

      check_validity_of_inverse!

      if !polymorphic? && (klass.composite_primary_key? || active_record.composite_primary_key?)
        if (has_one? || collection?) && Array(active_record_primary_key).length != Array(foreign_key).length
          raise ::ActiveRecord::Reflection::CompositePrimaryKeyMismatchError.new(self)
        elsif belongs_to? && Array(association_primary_key).length != Array(foreign_key).length
          raise ::ActiveRecord::Reflection::CompositePrimaryKeyMismatchError.new(self)
        end
      end

      cache[[object_id, :validated]] = true
    end

    # inverse_name writes @inverse_name on the frozen, shared reflection in a
    # worker Ractor (Rails only sets it lazily, so it is genuinely undefined on
    # a frozen object -> FrozenError). Cache it per-worker instead. Defined here
    # (not on AbstractReflection) because the original inverse_name lives on
    # AssociationReflection and would shadow an AbstractReflection-level override.
    def inverse_name
      rrs_refl_cache[[object_id, :inverse_name]] ||= (options.fetch(:inverse_of) { automatic_inverse_of })
    end

    def join_table
      rrs_refl_cache[[object_id, :join_table]] ||= -(options[:join_table]&.to_s || derive_join_table)
    end

    def foreign_key(infer_from_inverse_of: true)
      rrs_refl_cache[[object_id, :foreign_key, infer_from_inverse_of]] ||=
        if options[:foreign_key]
          if options[:foreign_key].is_a?(Array)
            options[:foreign_key].map { |fk| -fk.to_s.freeze }.freeze
          else
            options[:foreign_key].to_s.freeze
          end
        elsif options[:query_constraints]
          options[:query_constraints].map { |fk| -fk.to_s.freeze }.freeze
        else
          derived_fk = derive_foreign_key(infer_from_inverse_of: infer_from_inverse_of)

          if active_record.has_query_constraints?
            derived_fk = derive_fk_query_constraints(derived_fk)
          end

          if derived_fk.is_a?(Array)
            derived_fk.map! { |fk| -fk.freeze }
            derived_fk.freeze
          else
            -derived_fk.freeze
          end
        end
    end

    def association_foreign_key
      rrs_refl_cache[[object_id, :association_foreign_key]] ||= -(options[:association_foreign_key]&.to_s || class_name.foreign_key)
    end

    def active_record_primary_key
      custom_primary_key = options[:primary_key]
      rrs_refl_cache[[object_id, :active_record_primary_key]] ||=
        if custom_primary_key
          if custom_primary_key.is_a?(Array)
            custom_primary_key.map { |pk| pk.to_s.freeze }.freeze
          else
            custom_primary_key.to_s.freeze
          end
        elsif active_record.has_query_constraints? || options[:query_constraints]
          active_record.query_constraints_list
        elsif active_record.composite_primary_key?
          primary_key = primary_key(active_record)
          primary_key.include?("id") ? "id" : primary_key.freeze
        else
          primary_key(active_record).freeze
        end
    end

    def association_primary_key(klass = nil)
      if primary_key = options[:primary_key]
        rrs_refl_cache[[object_id, :association_primary_key, klass]] ||=
          if primary_key.is_a?(Array)
            primary_key.map { |pk| pk.to_s.freeze }.freeze
          else
            -primary_key.to_s
          end
      elsif (klass || self.klass).has_query_constraints? || options[:query_constraints]
        rrs_refl_cache[[object_id, :association_primary_key, klass]] ||= -Array(active_record.query_constraints_list).first.to_s
      elsif active_record.composite_primary_key?
        rrs_refl_cache[[object_id, :association_primary_key, klass]] ||= primary_key(klass || self.klass)
      else
        rrs_refl_cache[[object_id, :association_primary_key, klass]] ||= primary_key(klass || self.klass).to_s
      end
    end
  end

  module ReflectionThroughPatch
    prepend ReflectionMemoPatch

    def klass
      rrs_refl_cache[[object_id, :klass]] ||= delegate_reflection.klass
    end

    def association_primary_key(klass = nil)
      if primary_key = actual_source_reflection.options[:primary_key]
        rrs_refl_cache[[object_id, :association_primary_key, klass]] ||= -primary_key.to_s
      else
        rrs_refl_cache[[object_id, :association_primary_key, klass]] ||= primary_key(klass || self.klass)
      end
    end

    def source_reflection_name
      rrs_refl_cache[[object_id, :source_reflection_name]] ||= begin
        # The constructor sets @source_reflection_name from options[:source]
        # (e.g. has_one :avatar_blob, through: :avatar_attachment, source: :blob
        # sets it to :blob). If already set, use it — the fallback computation
        # below derives from `name` (e.g. :avatar_blob) and would NOT find the
        # :blob association on the through model.
        names = if options[:source]
          [options[:source]]
        else
          [name.to_s.singularize, name].collect(&:to_sym).uniq
        end
        names = names.find_all { |n|
          through_reflection.klass._reflect_on_association(n)
        }

        if names.length > 1
          raise AmbiguousSourceReflectionForThroughAssociation.new(
            active_record.name,
            through_reflection.name,
            source_reflection.plural_name,
            names
          )
        end

        names.first
      end
    end

    # ThroughReflection has its OWN check_validity! (distinct from
    # AssociationReflection#check_validity!) that writes @validated on the
    # frozen, shared reflection — raises FrozenError in a worker Ractor.
    # Reimplement it to store the validated flag in the per-worker cache
    # instead. The body mirrors Rails' ThroughReflection#check_validity!
    # (minus the @validated write).
    def check_validity!
      cache = rrs_refl_cache
      return if cache[[object_id, :validated]]

      if through_reflection.nil?
        raise ::ActiveRecord::HasManyThroughAssociationNotFoundError.new(active_record, self)
      end

      if through_reflection.polymorphic?
        if has_one?
          raise ::ActiveRecord::HasOneAssociationPolymorphicThroughError.new(active_record.name, self)
        else
          raise ::ActiveRecord::HasManyThroughAssociationPolymorphicThroughError.new(active_record.name, self)
        end
      end

      if source_reflection.nil?
        raise ::ActiveRecord::HasManyThroughSourceAssociationNotFoundError.new(self)
      end

      if options[:source_type] && !source_reflection.polymorphic?
        raise ::ActiveRecord::HasManyThroughAssociationPointlessSourceTypeError.new(active_record.name, self, source_reflection)
      end

      if source_reflection.polymorphic? && options[:source_type].nil?
        raise ::ActiveRecord::HasManyThroughAssociationPolymorphicSourceError.new(active_record.name, self, source_reflection)
      end

      if has_one? && through_reflection.collection?
        raise ::ActiveRecord::HasOneThroughCantAssociateThroughCollection.new(active_record.name, self, through_reflection)
      end

      if parent_reflection.nil?
        reflections = active_record.normalized_reflections.keys

        if reflections.index(through_reflection.name) > reflections.index(name)
          raise ::ActiveRecord::HasManyThroughOrderError.new(active_record.name, self, through_reflection)
        end
      end

      check_validity_of_inverse!

      cache[[object_id, :validated]] = true
    end

    def deprecated_nested_reflections
      rrs_refl_cache[[object_id, :deprecated_nested_reflections]] ||= collect_deprecated_nested_reflections
    end
  end

  class << self
    def _install_activerecord_reflection_patch
      return if @ar_reflection_patched
      @ar_reflection_patched = true
      # Apply now if AR is already loaded, otherwise hook active_record's load
      # (before eager-load builds the app's reflections). Never force a
      # `require "active_record"` here — that would double-load AR under
      # `bundle exec` and re-define constants after the shim froze them.
      if defined?(::ActiveRecord::Reflection::AbstractReflection)
        _apply_activerecord_reflection_patch
      else
        ActiveSupport.on_load(:active_record) do
          RactorRailsShim.__send__(:_apply_activerecord_reflection_patch)
        end
      end
    end

    def _apply_activerecord_reflection_patch
      return unless defined?(::ActiveRecord::Reflection::AbstractReflection)

      ::ActiveRecord::Reflection::AbstractReflection.prepend(ReflectionAbstractPatch)
      ::ActiveRecord::Reflection::MacroReflection.prepend(ReflectionMacroPatch)
      ::ActiveRecord::Reflection::AssociationReflection.prepend(ReflectionAssociationPatch)
      ::ActiveRecord::Reflection::ThroughReflection.prepend(ReflectionThroughPatch)
      _register_patch :activerecord_reflection, "8.1"
    end
  end
end
