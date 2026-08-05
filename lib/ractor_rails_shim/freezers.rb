# frozen_string_literal: true

# Freezers: the freeze/warm sub-domain extracted from the RactorRailsShim
# god module (Issue #1, CODE_REVIEW.md).
#
# `prepare_for_ractors!` calls five private methods that each handle one
# distinct responsibility of the pre-spawn shareability graph:
#
#   _warm_active_record_class_caches!   → CacheWarmer
#   _freeze_active_record_class_ivars!  → ClassIvarFreezer (AR models)
#   _freeze_global_class_ivars!         → GlobalClassIvarFreezer
#   _freeze_global_constants!           → GlobalConstantFreezer
#   _freeze_messages_constants!         → MessagesConstantsFreezer
#
# Each is extracted as its own object under RactorRailsShim::Freezers::* so
# it is independently specable (POODR: one responsibility per object). The
# RactorRailsShim singleton keeps facade methods that delegate, preserving
# the existing public/private API and the naming-convention spec.
#
# All objects share the shim's `_swallow` debug funnel and `_safe_const_get`
# helper via the RactorRailsShim singleton — they are collaborators of the
# orchestrator, not standalone services, so they reach the funnel through
# the facade rather than duplicating it.

module RactorRailsShim
  module Freezers
    # Warm ActiveRecord model classes' lazily-computed, shareable class-ivar
    # memoizations in the MAIN Ractor, BEFORE the graph is frozen. Methods like
    # the timestamp_attribute_* helpers cache frozen Arrays of strings
    # (shareable once warmed), so pre-populating them here lets workers read
    # via `||=` without ever setting the class ivar. (Class ivars holding
    # unshareable values are handled by ClassIvarFreezer.)
    module CacheWarmer
      # The set of AR class methods whose memoized results are shareable once
      # computed. Frozen so a worker can read it without isolation concerns.
      WARMER_METHODS = Ractor.make_shareable(%i[
        timestamp_attributes_for_create_in_model
        timestamp_attributes_for_update_in_model
        all_timestamp_attributes_in_model
        sequence_name
        columns
        column_names
        attribute_names
        column_defaults
        symbol_column_to_string_name_hash
        returning_columns_for_insert
        yaml_encoder
        attribute_types
      ].freeze)

      # Warm every non-abstract AR model's caches. No-op when ActiveRecord
      # is not loaded. Failures on individual (model, method) pairs are
      # funneled through _swallow so debug=true surfaces them.
      def self.call
        return true unless defined?(::ActiveRecord::Base)
        models = [::ActiveRecord::Base] + (::ActiveRecord::Base.descendants rescue [])
        models.each do |klass|
          next if klass.respond_to?(:abstract_class?) && klass.abstract_class?
          WARMER_METHODS.each do |m|
            next unless klass.respond_to?(m, true)
            RactorRailsShim._swallow("warm AR cache #{klass}##{m}") do
              klass.send(m)
            end
          end
        end
        true
      end
    end

    # Freeze (make Ractor-shareable) unshareable class-level instance variables
    # on ActiveRecord model classes (e.g. @columns_hash, @attribute_types,
    # @yaml_encoder, @dangerous_attribute_methods, ...). A worker Ractor cannot
    # read an unshareable class-ivar value (Ractor::IsolationError) nor set one.
    # Freezing them in main (where setting is allowed) yields shareable values
    # that workers read without writing. AR Type objects freeze cleanly, so this
    # is behavior-preserving; per-request code never mutates model class ivars.
    #
    # NOTE: do NOT skip abstract classes (e.g. a primary_abstract_class
    # ApplicationRecord). Workers recurse into them via
    # apply_pending_attribute_modifications, so their class ivars must also
    # be shareable.
    module ClassIvarFreezer
      def self.call
        return true unless defined?(::ActiveRecord::Base)
        models = [::ActiveRecord::Base] + (::ActiveRecord::Base.descendants rescue [])
        models.each do |klass|
          klass.instance_variables.each do |ivar|
            val = klass.instance_variable_get(ivar)
            next if Ractor.shareable?(val)
            RactorRailsShim._swallow("freeze AR ivar #{klass.name}#{ivar}") do
              Ractor.make_shareable(val)
            end
          end
        end
        true
      end
    end
  end
end