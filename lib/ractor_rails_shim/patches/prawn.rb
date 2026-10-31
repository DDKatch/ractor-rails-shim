# frozen_string_literal: true

# Patch Prawn's class-level state for worker Ractors (PDF generation happens
# per-request in this app — the request path, not just rake).
#
#   1. `Prawn::Fonts::AFM.font_data` — a lazily-memoized module ivar holding a
#      SynchronizedCache (a Hash whose instances own a Mutex). Workers both
#      READ the module ivar (raise) and WRITE parsed font data into it
#      (`afm.rb:88 self.class.font_data[file_name] ||= parse_afm(...)`,
#      raise). Fix: per-Ractor caches via ::RactorRailsShim.storage — main keeps
#      its shared parsed-AFM cache; each worker parses (and caches) its own.
#      Parsing is pure file I/O + Hash building, so it is Ractor-safe.
#
#   2. `Prawn::Fonts::AFM.metrics_path` — `@metrics_path ||= [ENV['METRICS']
#      ? ... : [...]]` is a first-use module-ivar write; workers raise. Fix:
#      worker reads get a frozen Array cached per-Ractor (same data as main).
#
#   3. `Prawn::Repeater.count` — a global counter (`@count ||= 0`, `@count +=
#      1` per `Repeater.new`, `repeater.rb:109-114`) used for unique stamp
#      names. Worker writes raise. Fix: per-Ractor counters via storage —
#      uniqueness only needs to hold per document.
#
#   4. `Prawn.image_handler` / `Prawn::Document.extensions` — boot-populated
#      registries (ImageHandler's @handlers holds image classes; extensions
#      holds Modules). Both are frozen IN PLACE at freeze time via the
#      SHAREABLE_CLASS_IVARS registry, so the original lazy accessors become
#      worker-safe reads (`||=` never fires on the non-nil frozen value).

module RactorRailsShim
  SHAREABLE_CLASS_IVARS.concat([
    ["Prawn", :@image_handler],
    ["Prawn::Document", :@extensions],
    ["Prawn::Fonts::AFM", :@metrics_path]
  ])

  class << self
    def _install_prawn_patch
      return if @prawn_patched
      @prawn_patched = true
      _register_patch :prawn, "8.1"
      return unless defined?(::Prawn)

      _install_prawn_afm_caches
      _install_prawn_repeater_counter
    end

    private

    def _install_prawn_afm_caches
      return unless defined?(::Prawn::Fonts::AFM)
      ::Prawn::Fonts::AFM.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def font_data
          if ::Ractor.main?
            @font_data ||= ::Prawn::SynchronizedCache.new
          else
            key = :ractor_rails_shim_prawn_afm_font_data
            ::RactorRailsShim.storage[key] ||= ::Prawn::SynchronizedCache.new
            ::RactorRailsShim.storage[key]
          end
        end

        def metrics_path
          if ::Ractor.main?
            @metrics_path ||=
              if ENV['METRICS']
                ENV['METRICS'].split(':')
              else
                ['.', '/usr/lib/afm', '/usr/local/lib/afm',
                 '/usr/openwin/lib/fonts/afm',
                 "\#{::Prawn::DATADIR}/fonts"]
              end
          else
            key = :ractor_rails_shim_prawn_afm_metrics_path
            # No ENV read here: ENV access is not Ractor-safe. The
            # METRICS override is a debugging knob (main-only concern).
            ::RactorRailsShim.storage[key] ||= ['.', '/usr/lib/afm',
              '/usr/local/lib/afm', '/usr/openwin/lib/fonts/afm',
              "\#{::Prawn::DATADIR}/fonts"].freeze
            ::RactorRailsShim.storage[key]
          end
        end
      RUBY
    end

    def _install_prawn_repeater_counter
      return unless defined?(::Prawn::Repeater)
      ::Prawn::Repeater.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def count
          key = :ractor_rails_shim_prawn_repeater_count
          ::RactorRailsShim.storage[key] ||= 0
          ::RactorRailsShim.storage[key]
        end

        def count=(value)
          ::RactorRailsShim.storage[:ractor_rails_shim_prawn_repeater_count] = value
        end
      RUBY
    end
  end
end
