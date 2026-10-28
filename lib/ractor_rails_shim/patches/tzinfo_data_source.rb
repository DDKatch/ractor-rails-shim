# frozen_string_literal: true

# `RactorRailsShim::Patches::TzinfoDataSource` — the role object that owns
# the TZInfo::DataSource patch.
#
# Background: every `ActiveSupport::TimeZone` creation resolves its TZInfo
# data through `TZInfo::DataSource.get`, which memoizes into the CLASS
# VARIABLES @@instance / @@default_mutex. Ruby 4.0 forbids ANY class-
# variable access from a non-main Ractor (Ractor::IsolationError: can not
# access class variables from non-main Ractors), so a worker-side zone
# creation — reached via the patched `ActiveSupport::TimeZone.[]` from
# `Time.zone` / `use_zone` / `in_time_zone` — dies.
#
# The patch makes `get` Ractor-aware:
#   - MAIN: the upstream body verbatim (class-variable memoize + mutex).
#   - Workers: a per-Ractor DataSource from IsolatedExecutionState. The
#     upstream `create_default_data_source` (private class method, called
#     with the same class context) chooses ruby-data or zoneinfo exactly
#     like main; each worker caches its own instance (DataSource instances
#     carry per-instance lookup caches, so per-Ractor caching is
#     semantically equivalent).
#
# The patch is installed with `singleton_class.class_eval` (the main branch
# reimplements upstream verbatim because the replacement removes the
# original — same technique as the Concurrent global executor patch). This
# object owns the idempotency flag (`@installed`). The facade method
# `_install_tzinfo_data_source_patch` (patches/core.rb) delegates here.

module RactorRailsShim
  module Patches
    module TzinfoDataSource
      @installed = false
      @mutex = Mutex.new

      def self.install
        @mutex.synchronize do
          return true if @installed
          return true unless defined?(::TZInfo::DataSource)

          ::TZInfo::DataSource.singleton_class.class_eval <<~RUBY, __FILE__, __LINE__ + 1
            def get
              if ::Ractor.main?
                # Upstream body verbatim (class-variable memoize + mutex).
                # NOTE: class variables are referenced via class_variable_get
                # because class_eval(String) compiles them against the
                # loading module's lexical scope, not this class.
                unless class_variable_get(:@@instance)
                  class_variable_get(:@@default_mutex).synchronize do
                    set(create_default_data_source) unless class_variable_get(:@@instance)
                  end
                end
                class_variable_get(:@@instance)
              else
                # Workers may not touch the class variables
                # (Ractor::IsolationError) — a per-Ractor DataSource from
                # IsolatedExecutionState. Workers never mutate the
                # selection (the upstream `set` stays main-only).
                ::RactorRailsShim.storage[:rrs_tzinfo_data_source] ||= create_default_data_source
              end
            end
          RUBY

          # ZoneinfoDataSource's constructor discovers the system zoneinfo
          # directory through two class-variable-reading class methods.
          # Workers re-derive the upstream defaults (frozen copies from the
          # private DEFAULT_* constants — the same paths upstream starts
          # from); the writers stay main-only.
          if defined?(::TZInfo::DataSources::ZoneinfoDataSource)
            zds = ::TZInfo::DataSources::ZoneinfoDataSource
            # Read the private DEFAULT_* constants at install time (main
            # side) and interpolate the frozen values into the eval'd body —
            # a `::Full::Path::CONST` reference to a private constant raises
            # NameError at runtime.
            default_search_path = zds.const_get(:DEFAULT_SEARCH_PATH).dup.freeze
            default_alt_iso3166 = zds.const_get(:DEFAULT_ALTERNATE_ISO3166_TAB_SEARCH_PATH).dup.freeze
            zds.singleton_class.class_eval <<~RUBY, __FILE__, __LINE__ + 1
              def search_path
                if ::Ractor.main?
                  class_variable_get(:@@search_path)
                else
                  ::RactorRailsShim.storage[:rrs_tzinfo_search_path] ||=
                    #{default_search_path.inspect}.freeze
                end
              end

              def alternate_iso3166_tab_search_path
                if ::Ractor.main?
                  class_variable_get(:@@alternate_iso3166_tab_search_path)
                else
                  ::RactorRailsShim.storage[:rrs_tzinfo_alt_iso3166_search_path] ||=
                    #{default_alt_iso3166.inspect}.freeze
                end
              end
            RUBY
          end

          @installed = true
        end
        true
      end

      def self.installed?
        @installed
      end
    end
  end
end
