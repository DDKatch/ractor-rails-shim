# frozen_string_literal: true

# RAILS_FEATURES.md #105 (turbo-rails adoption). Three turbo-rails setup
# paths compile un-shareable Procs into ActionController::Base at boot, all
# of which run on worker-served renders:
#
# 1. The `turbo.renderer` initializer:
#      ActionController::Renderers.add :turbo_stream do |html, options| ... end
#    → `define_method(:_render_with_renderer_turbo_stream, &block)` — calling
#    it from a worker raises "defined with an un-shareable Proc in a
#    different Ractor".
# 2. The `Turbo::Frames::FrameRequest` include:
#      layout -> { "turbo_rails/frame" if turbo_frame_request? }
#    → Rails' `_write_layout_method` emits
#      `define_method :_layout_from_proc, &_layout` — and the Layouts
#    `inherited` hook re-runs `_write_layout_method` on EVERY controller
#    subclass, so each controller carries its own un-callable method.
# 3. `Turbo.current_request_id` / `ActiveRecord::Base
#    .suppressed_turbo_broadcasts` are `thread_mattr_accessor`s whose
#    generated methods memoize their IES key in a class/module ivar
#    (`@__thread_mattr_#{sym} ||=`) — handled generically by
#    `_install_thread_mattr_patch` (install-time macro patch), not here.
#
# Fix: same recipe as `_install_json_renderer_patch` — string-eval'd `def`s
# with no captured binding. The renderer body references only the receiver
# and shareable constants. The layout proc is stored in a frozen registry
# constant (deep-frozen by the shareability pipeline like every other
# captured Proc) that a real `def` reads through.

module RactorRailsShim
  module Patches
    module TurboPatch
      module_function

      def apply!
        return true if @applied
        RactorRailsShim.__send__(:_register_patch, :turbo, "8.1")

        # The renderer re-emit must run AFTER turbo's `turbo.renderer`
        # initializer (its define_method would otherwise overwrite a
        # pre-emptive def). Patches dispatch at prepare time (post-boot),
        # where the renderer exists; if not (very-early dispatch), leave
        # @applied false so the make_app_shareable! dispatch retries.
        if defined?(::ActionController::Renderers) &&
            ::ActionController::Renderers::RENDERERS.include?(:turbo_stream)
          emit_turbo_stream_renderer_def!
          @applied = true
        end

        install_proc_layout_emitter!
        true
      end

      def emit_turbo_stream_renderer_def!
        return unless defined?(::ActionController::Renderers) &&
          ::ActionController::Renderers::RENDERERS.include?(:turbo_stream)
        ::ActionController::Renderers.module_eval(<<-RUBY, __FILE__, __LINE__ + 1)
          remove_method :_render_with_renderer_turbo_stream if method_defined?(:_render_with_renderer_turbo_stream)
          def _render_with_renderer_turbo_stream(turbo_streams_html, options)
            self.content_type = Mime[:turbo_stream] if media_type.nil?
            turbo_streams_html
          end
        RUBY
      end

      # (2) Post-process `_write_layout_method`: after Rails' original emits
      # the define_method'd `_layout_from_proc` for a Proc layout, rebind it
      # through the frozen registry + a real def. Runs for every controller
      # class (the `layout` macro and the `inherited` hook both re-emit), so
      # install must happen BEFORE eager load — deferred via
      # on_load(:action_controller_base).
      def install_proc_layout_emitter!
        return true unless defined?(::ActionController::Base) && ::ActionController::Base.respond_to?(:_write_layout_method, true)
        return emit_now!

        unless defined?(ActiveSupport.on_load)
          require "active_support/lazy_load_hooks"
        end
        ActiveSupport.on_load(:action_controller_base) { RactorRailsShim::Patches::TurboPatch.emit_now! }
      end

      def emit_now!
        return true unless defined?(::ActionView::Layouts)
        cm = ::ActionView::Layouts::ClassMethods
        return true if cm.instance_method(:_write_layout_method).source_location&.first.to_s.end_with?("turbo.rb")

        cm.module_eval(<<-'RUBY', __FILE__, __LINE__ + 1)
          alias_method :__rrs_original_write_layout_method, :_write_layout_method
          def _write_layout_method
            __rrs_original_write_layout_method
            p = _layout
            return unless p.is_a?(::Proc)
            key = "rrs_layout_proc_" + (name || "anonymous_" + object_id.to_s)
            ::RactorRailsShim::PROC_LAYOUT_PROCS[key] = p
            silence_redefinition_of_method(:_layout_from_proc)
            class_eval(<<-EOS, __FILE__, __LINE__ + 1)
              def _layout_from_proc(*args)
                proc = ::RactorRailsShim::PROC_LAYOUT_PROCS[#{key.inspect}]
                return nil unless proc
                # instance_exec rebinds self to the controller instance, the
                # same contract define_method(&proc) has upstream (the proc
                # body calls turbo_frame_request? as an instance method).
                args.empty? ? instance_exec(&proc) : instance_exec(args.first, &proc)
              end
            EOS
            private :_layout_from_proc
          end
        RUBY
        true
      end
    end
  end

  def self._install_turbo_patch = Patches::TurboPatch.apply!

  # Pipeline step (after Proc/lock replacement, before the registry freeze):
  # EVERY controller class re-runs Rails' `_write_layout_method` via the
  # Layouts `inherited` hook at eager-load, which re-emits
  # `define_method :_layout_from_proc, &_layout` bound to the ORIGINAL
  # (main-compiled) proc object — per controller class. Replacing the
  # class_attribute `_layout` VALUE with its shareable deep-frozen copy does
  # NOT rebind the method. Re-run the emission: the patched version routes
  # through PROC_LAYOUT_PROCS + a real def, so this is only needed for
  # classes eager-loaded BEFORE the emitter patch installed (belt and
  # braces for unusual boot orders).
  def self._reemit_proc_layouts!
    return true unless defined?(::ActionView::Layouts) && defined?(::ActionController::Base)
    classes = [::ActionController::Base]
    classes.concat(::ActionController::Base.descendants) rescue nil
    classes.each do |klass|
      layout = klass._layout rescue nil
      next unless layout.is_a?(::Proc)
      begin
        Ractor.make_shareable(layout) unless (Ractor.shareable?(layout) rescue false)
        klass.__send__(:_write_layout_method)
      rescue StandardError, Ractor::Error
        nil
      end
    end
    true
  end

  # Pipeline step (before the final make_shareable): freeze the layout-proc
  # registry into a shareable constant. Procs whose captured state can not be
  # shared are DROPPED (the worker's `_layout_from_proc` then reads nil and
  # Rails falls back to the default layout — safe degrade).
  def self._freeze_proc_layout_registry!
    return true unless RactorRailsShim.const_defined?(:PROC_LAYOUT_PROCS, false)
    src = RactorRailsShim::PROC_LAYOUT_PROCS
    return true if Ractor.shareable?(src)

    table = {}
    src.each do |k, p|
      if Ractor.shareable?(p)
        table[k] = p
        next
      end
      begin
        Ractor.make_shareable(p)
        table[k] = p
      rescue StandardError, Ractor::Error
        nil
      end
    end
    begin
      Ractor.make_shareable(table)
      RactorRailsShim.__send__(:_reassign_shareable_const, :PROC_LAYOUT_PROCS, table)
    rescue StandardError, Ractor::Error
      nil
    end
    true
  end
end
