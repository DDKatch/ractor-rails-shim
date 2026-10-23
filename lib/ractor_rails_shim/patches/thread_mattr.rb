# frozen_string_literal: true

# `Module#thread_mattr_accessor` (and its reader/writer halves) generate
# methods that memoize the per-thread IsolatedExecutionState key in a
# class/module INSTANCE IVAR:
#
#   def self.#{sym}
#     @__thread_mattr_#{sym} ||= "attr_#{sym}_#{object_id}"
#     ActiveSupport::IsolatedExecutionState[@__thread_mattr_#{sym}]
#   end
#
# That `||=` is a module/class-ivar write, which a worker Ractor can not do
# (Ractor::IsolationError: can not set instance variables of classes/modules
# by non-main Ractors). With turbo-rails adopted, EVERY worker request died:
# the `Turbo::RequestIdTracking` around_action reads/writes
# `Turbo.current_request_id` (a thread_mattr_accessor), and
# `Turbo::Broadcastable`'s `suppressed_turbo_broadcasts` (a thread_mattr on
# ActiveRecord::Base) is read on every model broadcast.
#
# Fix: regenerate the generated methods WITHOUT the ivar memo. The key is
# deterministic per class anyway (`attr_#{sym}_#{object_id}` — the escaped
# interpolation evaluates at call time, so subclasses keep their independent
# keys exactly like upstream); computing it per call is equivalent behavior
# with zero module-ivar writes. Values still live in the shim's per-Ractor
# IsolatedExecutionState, so per-Ractor / per-thread isolation is preserved.
#
# Load order: this file is required at shim install time, BEFORE
# `Bundler.require` loads app gems — so every gem-defined thread_mattr
# (turbo-rails is the only Rails-ecosystem user) is generated with the
# patched macros and needs no regeneration.

module RactorRailsShim
  module Patches
    module ThreadMattrPatch
      module_function

      def apply!
        return true if @applied
        @applied = true
        RactorRailsShim.__send__(:_register_patch, :thread_mattr, "8.1")
        require "active_support/core_ext/module/attribute_accessors_per_thread"
        ::Module.class_eval(<<-'RUBY', __FILE__, __LINE__ + 1)
          alias_method :__rrs_original_thread_mattr_reader, :thread_mattr_reader
          alias_method :__rrs_original_thread_mattr_writer, :thread_mattr_writer

          def thread_mattr_reader(*syms, instance_reader: true, instance_accessor: true, default: nil) # :nodoc:
            syms.each do |sym|
              raise NameError.new("invalid attribute name: \#{sym}") unless /^[_A-Za-z]\w*$/.match?(sym.to_s)

              if default.nil?
                class_eval(<<-EOS, __FILE__, __LINE__ + 1)
                  def self.#{sym}
                    ::ActiveSupport::IsolatedExecutionState["attr_#{sym}_\#{object_id}"]
                  end
                EOS
              else
                default = default.dup.freeze unless default.frozen?
                singleton_class.define_method("#{sym}_default_value") { default }

                class_eval(<<-EOS, __FILE__, __LINE__ + 1)
                  def self.#{sym}
                    key = "attr_#{sym}_\#{object_id}"
                    value = ::ActiveSupport::IsolatedExecutionState[key]

                    if value.nil? && !::ActiveSupport::IsolatedExecutionState.key?(key)
                      ::ActiveSupport::IsolatedExecutionState[key] = #{sym}_default_value
                    else
                      value
                    end
                  end
                EOS
              end

              if instance_reader && instance_accessor
                class_eval(<<-EOS, __FILE__, __LINE__ + 1)
                  def #{sym}
                    self.class.#{sym}
                  end
                EOS
              end
            end
          end
          alias :thread_cattr_reader :thread_mattr_reader

          def thread_mattr_writer(*syms, instance_writer: true, instance_accessor: true) # :nodoc:
            syms.each do |sym|
              raise NameError.new("invalid attribute name: \#{sym}") unless /^[_A-Za-z]\w*$/.match?(sym.to_s)

              class_eval(<<-EOS, __FILE__, __LINE__ + 1)
                def self.#{sym}=(obj)
                  ::ActiveSupport::IsolatedExecutionState["attr_#{sym}_\#{object_id}"] = obj
                end
              EOS

              if instance_writer && instance_accessor
                class_eval(<<-EOS, __FILE__, __LINE__ + 1)
                  def #{sym}=(obj)
                    self.class.#{sym} = obj
                  end
                EOS
              end
            end
          end
          alias :thread_cattr_writer :thread_mattr_writer
        RUBY
        true
      end
    end
  end

  def self._install_thread_mattr_patch = Patches::ThreadMattrPatch.apply!
end
