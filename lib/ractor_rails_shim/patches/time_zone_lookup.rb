# frozen_string_literal: true

# `RactorRailsShim::Patches::TimeZoneLookup` — the role object that owns the
# ActiveSupport::TimeZone lookup patch.
#
# Background: `Time.zone` (and every `in_time_zone` / `use_zone` call)
# resolves zones through `ActiveSupport::TimeZone.[]`, whose String branch
# memoizes into the class ivar `@lazy_zones_map` — a
# `Concurrent::Map.new` set at load time. Both halves are forbidden in
# workers: reading the unshareable Concurrent::Map class ivar raises
# Ractor::IsolationError (can not get unshareable values from instance
# variables of classes/modules), and a worker-side `||=` memoize would try
# to set it. So a worker-side `Time.use_zone("UTC") { ... }` /
# `Time.find_zone!("Europe/Berlin")` dies.
#
# The patch makes `[]` Ractor-aware:
#   - MAIN: the upstream body verbatim (lazy class-ivar Concurrent::Map).
#   - Workers: a per-Ractor zone cache in IsolatedExecutionState; misses
#     create a worker-local TimeZone via the normal `create` path (TZInfo
#     data lookups are worker-safe). Zone instances are plain data, so
#     worker-local caches are semantically equivalent to the main cache.
#
# The patch is installed with `singleton_class.class_eval` (the main branch
# reimplements upstream verbatim because the replacement removes the
# original). This object owns the idempotency flag (`@installed`). The
# facade method `_install_time_zone_lookup_patch` (patches/core.rb)
# delegates here.

module RactorRailsShim
  module Patches
    module TimeZoneLookup
      @installed = false
      @mutex = Mutex.new

      def self.install
        @mutex.synchronize do
          return true if @installed
          return true unless defined?(::ActiveSupport::TimeZone)

          ::ActiveSupport::TimeZone.singleton_class.class_eval <<~RUBY, __FILE__, __LINE__ + 1
            def [](arg)
              if ::Ractor.main?
                # Upstream body verbatim (lazy class-ivar Concurrent::Map).
                case arg
                when self
                  arg
                when String
                  begin
                    @lazy_zones_map[arg] ||= create(arg)
                  rescue TZInfo::InvalidTimezoneIdentifier
                    nil
                  end
                when TZInfo::Timezone
                  @lazy_zones_map[arg.name] ||= create(arg.name, nil, arg)
                when Numeric, ActiveSupport::Duration
                  arg *= 3600 if arg.abs <= 13
                  all.find { |z| z.utc_offset == arg.to_i }
                else
                  raise ArgumentError, "invalid argument to TimeZone[]: \#{arg.inspect}"
                end
              else
                # Workers may not read the unshareable Concurrent::Map class
                # ivar (IsolationError) — use a per-Ractor Hash cache. The
                # numeric branch's `all` also reads class ivars, so it is
                # main-only; workers resolve String/TZInfo zones.
                case arg
                when self
                  arg
                when String, TZInfo::Timezone
                  cache = ::RactorRailsShim.storage[:rrs_time_zone_lookup] ||= {}
                  name = arg.is_a?(String) ? arg : arg.name
                  begin
                    cache[name] ||= create(name)
                  rescue TZInfo::InvalidTimezoneIdentifier
                    nil
                  end
                else
                  raise ArgumentError, "invalid argument to TimeZone[]: \#{arg.inspect}"
                end
              end
            end
          RUBY

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
