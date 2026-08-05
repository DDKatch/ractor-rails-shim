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

    # Freeze (make Ractor-shareable) unshareable class-level ivars on GLOBAL
    # classes (Time/Date timezone caches, I18n locale caches, ...) in the MAIN
    # Ractor, before the graph is frozen. Unlike model classes, these are shared
    # singletons whose class ivars (e.g. Time's @zone_default / @zone_cache)
    # hold unshareable values that a worker Ractor would otherwise fail to read
    # (Ractor::IsolationError). Freezing them in main yields shareable values.
    module GlobalClassIvarFreezer
      # The set of global class names whose ivars are frozen. Frozen so the
      # list is shareable and stable.
      TARGETS = Ractor.make_shareable(%w[Time Date DateTime I18n].freeze)

      def self.call
        classes = TARGETS.filter_map { |n| RactorRailsShim._safe_const_get(n) }
        classes.each do |klass|
          klass.instance_variables.each do |ivar|
            val = klass.instance_variable_get(ivar)
            next if Ractor.shareable?(val)
            RactorRailsShim._swallow("freeze global ivar #{klass}#{ivar}") do
              Ractor.make_shareable(val)
            end
          end
        end
        true
      end
    end

    # Replace GLOBAL constants that hold non-shareable values (e.g.
    # Time/Date/DateTime::DATE_FORMATS contain Proc values) with frozen,
    # shareable equivalents so worker Ractors can read them. Proc-valued format
    # entries are dropped (to_fs falls back to to_s for those formats). This is
    # done in the MAIN Ractor, where const_set is allowed.
    module GlobalConstantFreezer
      # The set of module names whose DATE_FORMATS constant is frozen.
      # Frozen so the list is shareable and stable.
      TARGETS = Ractor.make_shareable(%w[Time Date DateTime].freeze)
      # The constant name on each target module that holds the format table.
      CONSTANT_NAME = :DATE_FORMATS

      def self.call
        constants = TARGETS.filter_map do |n|
          mod = RactorRailsShim._safe_const_get(n)
          mod.is_a?(Module) ? [mod, CONSTANT_NAME] : nil
        end
        constants.each do |mod, name|
          next unless mod.const_defined?(name, false)
          val = mod.const_get(name, false)
          next if Ractor.shareable?(val)
          shareable = if val.is_a?(Hash)
            h = {}
            val.each { |k, v| h[k] = v if Ractor.shareable?(v) }
            h.freeze
          elsif val.is_a?(Array)
            val.select { |v| Ractor.shareable?(v) }.freeze
          else
            val
          end
          begin
            mod.const_set(name, shareable)
          rescue StandardError
            nil
          end
        end
        true
      end
    end

    # ActiveSupport::Messages::Metadata holds non-shareable Array constants
    # (ENVELOPE_SERIALIZERS / TIMESTAMP_SERIALIZERS) of serializer Modules, used
    # by MessageEncryptor during flash/session cookie serialization. A worker
    # Ractor reading these constants (e.g. on `redirect_to`, which encrypts a
    # flash message) raises Ractor::IsolationError. The Arrays are shareable once
    # frozen (their elements are Modules), so deep-freeze and const_set the
    # shareable copy back so workers read a shareable constant.
    #
    # Loads ActiveSupport::MessagePack in the MAIN Ractor FIRST: metadata.rb
    # registers an `ActiveSupport.on_load(:message_pack)` callback that mutates
    # ENVELOPE_SERIALIZERS / TIMESTAMP_SERIALIZERS via `<<`. If that callback
    # first fires inside a worker Ractor (which happens the first time a
    # cookie's `detect_format` probes MessagePackWithFallback.dumped?, because
    # it lazily requires "active_support/message_pack"), it runs against the
    # already-frozen arrays and raises FrozenError. Loading here makes the
    # callback fire once, in main, against the non-frozen arrays; load hooks
    # never fire again in workers.
    module MessagesConstantsFreezer
      # The two Metadata constants that hold Arrays of serializer Modules.
      TARGET_NAMES = Ractor.make_shareable(%i[ENVELOPE_SERIALIZERS TIMESTAMP_SERIALIZERS].freeze)

      # True if the msgpack C extension is installed. Gem::LoadError is a
      # ScriptError (not StandardError), so a bare `rescue nil` on the require
      # would NOT catch a missing msgpack gem. active_support/message_pack
      # loads without it but prints a "requires the msgpack gem" warning to
      # $stderr before raising LoadError. Pre-checking avoids the warning
      # entirely and skips the freeze step cleanly when the C extension isn't
      # installed (e.g. in the gem's no-Rails unit specs).
      def self.msgpack_available?
        Gem::Specification.find_all_by_name("msgpack").any?
      end

      def self.call
        return true unless msgpack_available?
        _load_message_pack

        mod = RactorRailsShim._safe_const_get("ActiveSupport::Messages::Metadata", inherit: false)
        return true unless mod.is_a?(Module)
        TARGET_NAMES.each do |name|
          next unless mod.const_defined?(name, false)
          val = mod.const_get(name, false)
          next if Ractor.shareable?(val)
          shareable = Ractor.make_shareable(val) rescue val
          begin
            mod.const_set(name, shareable)
          rescue StandardError
            nil
          end
        end
        true
      end

      # Load active_support/message_pack in the MAIN Ractor. Extracted as a
      # seam so tests can stub the load (the real require raises Gem::LoadError
      # — a ScriptError — when the msgpack C extension isn't in the bundle).
      def self._load_message_pack
        require "active_support/message_pack"
      end
    end
  end
end