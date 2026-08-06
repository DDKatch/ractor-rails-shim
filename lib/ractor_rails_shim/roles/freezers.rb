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
# helper via the configure seam, defaulting to the facade lookups so existing
# call sites keep working (Issue #23, POODR §2 Dependencies).

module RactorRailsShim
  module Freezers
    module CacheWarmer
      extend RoleDefaults

      @funnel = nil

      def self.configure(funnel: nil)
        @funnel = funnel
      end

      def self.reset_configuration
        @funnel = nil
      end

      def self.funnel
        @funnel || default_funnel
      end

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

      def self.call
        return true unless defined?(::ActiveRecord::Base)
        ARModelWalker.each_model(skip_abstract: true) do |klass|
          WARMER_METHODS.each do |m|
            next unless klass.respond_to?(m, true)
            funnel.call("warm AR cache #{klass}##{m}") do
              klass.send(m)
            end
          end
        end
        true
      end
    end

    module ClassIvarFreezer
      extend RoleDefaults

      @funnel = nil

      def self.configure(funnel: nil)
        @funnel = funnel
      end

      def self.reset_configuration
        @funnel = nil
      end

      def self.funnel
        @funnel || default_funnel
      end

      def self.call
        return true unless defined?(::ActiveRecord::Base)
        ARModelWalker.each_model do |klass|
          klass.instance_variables.each do |ivar|
            val = klass.instance_variable_get(ivar)
            next if Ractor.shareable?(val)
            funnel.call("freeze AR ivar #{klass.name}#{ivar}") do
              Ractor.make_shareable(val)
            end
          end
        end
        true
      end
    end

    module GlobalClassIvarFreezer
      extend RoleDefaults

      @funnel = nil
      @safe_const_get = nil

      def self.configure(funnel: nil, safe_const_get: nil)
        @funnel = funnel
        @safe_const_get = safe_const_get
      end

      def self.reset_configuration
        @funnel = nil
        @safe_const_get = nil
      end

      def self.funnel
        @funnel || default_funnel
      end

      def self.safe_const_get
        @safe_const_get || default_safe_const_get
      end

      # Mutable target list — downstream apps can register their own global
      # classes via add_target without monkey-patching. Read at boot time
      # (main Ractor only) before workers spawn.
      TARGETS = %w[Time Date DateTime I18n]

      def self.add_target(class_name)
        TARGETS << class_name unless TARGETS.include?(class_name)
      end

      def self.call
        classes = TARGETS.filter_map { |n| safe_const_get.call(n) }
        classes.each do |klass|
          klass.instance_variables.each do |ivar|
            val = klass.instance_variable_get(ivar)
            next if Ractor.shareable?(val)
            funnel.call("freeze global ivar #{klass}#{ivar}") do
              Ractor.make_shareable(val)
            end
          end
        end
        true
      end
    end

    module GlobalConstantFreezer
      extend RoleDefaults

      @safe_const_get = nil
      @funnel = nil

      def self.configure(safe_const_get: nil, funnel: nil)
        @safe_const_get = safe_const_get
        @funnel = funnel
      end

      def self.reset_configuration
        @safe_const_get = nil
        @funnel = nil
      end

      def self.safe_const_get
        @safe_const_get || default_safe_const_get
      end

      def self.funnel
        @funnel || default_funnel
      end

      # Mutable target list — downstream apps can register their own
      # DATE_FORMATS-style constants via add_target without monkey-patching.
      # Read at boot time (main Ractor only) before workers spawn.
      TARGETS = %w[Time Date DateTime]
      CONSTANT_NAME = :DATE_FORMATS

      def self.add_target(class_name)
        TARGETS << class_name unless TARGETS.include?(class_name)
      end

      def self.call
        constants = TARGETS.filter_map do |n|
          mod = safe_const_get.call(n)
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
            mod.send(:remove_const, name) if mod.const_defined?(name, false)
            mod.const_set(name, shareable)
          rescue StandardError => e
            funnel.call("freeze global constant #{mod}::#{name}") { raise e }
          end
        end
        true
      end
    end

    module MessagesConstantsFreezer
      extend RoleDefaults

      @safe_const_get = nil

      def self.configure(safe_const_get: nil)
        @safe_const_get = safe_const_get
      end

      def self.reset_configuration
        @safe_const_get = nil
      end

      def self.safe_const_get
        @safe_const_get || default_safe_const_get
      end

      # Mutable target list — downstream apps can register their own
      # message-serializer constants via add_target without monkey-patching.
      TARGET_NAMES = %i[ENVELOPE_SERIALIZERS TIMESTAMP_SERIALIZERS]

      def self.add_target(name)
        TARGET_NAMES << name unless TARGET_NAMES.include?(name)
      end

      def self.msgpack_available?
        Gem::Specification.find_all_by_name("msgpack").any?
      end

      def self.call
        return true unless msgpack_available?
        _load_message_pack

        mod = safe_const_get.call("ActiveSupport::Messages::Metadata", inherit: false)
        return true unless mod.is_a?(Module)
        TARGET_NAMES.each do |name|
          next unless mod.const_defined?(name, false)
          val = mod.const_get(name, false)
          next if Ractor.shareable?(val)
          shareable = Ractor.make_shareable(val) rescue val
          begin
            mod.send(:remove_const, name) if mod.const_defined?(name, false)
            mod.const_set(name, shareable)
          rescue StandardError
            nil
          end
        end
        true
      end

      def self._load_message_pack
        require "active_support/message_pack"
      end
    end

    # ShareableClassIvarFreezer: walks SHAREABLE_CLASS_IVARS (class name,
    # ivar name pairs), reads each ivar, makes it Ractor-shareable
    # (deep-frozen), and writes it back so workers read the shareable
    # copy. Also pre-touches memoizing accessors so workers don't try to
    # write the ivar lazily (which would raise FrozenError on the frozen
    # class). Extracted from _freeze_shareable_class_ivars! in
    # make_shareable.rb (Issue #27, POODR §6a Modules & Roles).
    module ShareableClassIvarFreezer
      extend RoleDefaults

      @funnel = nil
      @safe_const_get = nil

      def self.configure(funnel: nil, safe_const_get: nil)
        @funnel = funnel
        @safe_const_get = safe_const_get
      end

      def self.reset_configuration
        @funnel = nil
        @safe_const_get = nil
      end

      def self.funnel
        @funnel || default_funnel
      end

      def self.safe_const_get
        @safe_const_get || default_safe_const_get
      end

      # Mutable registry of [class_name, method_name] pairs to pre-touch
      # before the main shareable-class-ivar freeze. A pre-touch forces
      # lazy memoizing accessors to populate in the MAIN Ractor so workers
      # don't try to write the (now frozen) ivar on first read. Downstream
      # apps can register their own entries via add_pre_touch.
      PRE_TOUCH = [
        ["ActiveSupport::Editor", :current],
        ["Warden::Strategies", :_strategies],
      ]

      def self.add_pre_touch(class_name, method_name)
        PRE_TOUCH << [class_name, method_name] unless PRE_TOUCH.any? { |n, m| n == class_name && m == method_name }
      end

      def self.call
        RactorRailsShim::Registry.shareable_class_ivars.each do |(class_name, ivar)|
          mod = safe_const_get.call(class_name)
          next unless mod && mod.instance_variable_defined?(ivar)
          val = mod.instance_variable_get(ivar)
          next if val.nil?
          funnel.call("freeze global ivar #{class_name}#{ivar}") do
            Ractor.make_shareable(val)
            mod.instance_variable_set(ivar, val)
          end
        end
        # Pre-touch memoizing accessors so workers short-circuit instead of
        # writing the (now frozen) ivar on first read (FrozenError avoidance).
        # Walked from the PRE_TOUCH registry (Issue #41) — data-driven
        # instead of hardcoded.
        PRE_TOUCH.each do |class_name, method_name|
          mod = safe_const_get.call(class_name)
          next unless mod && mod.respond_to?(method_name, true)
          funnel.call("pre-touch #{class_name}.#{method_name}") do
            mod.send(method_name)
          end
        end
        true
      end
    end
  end
end