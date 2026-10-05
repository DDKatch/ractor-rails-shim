# frozen_string_literal: true

# Callbacks::DependentAssociationTransport — replays a model's `dependent:`
# association cascades on the `:destroy` kind. This is the reference transport
# for a callback that is a LAMBDA (the `dependent:` option registers an
# unshareable `before_destroy` lambda) but whose *effect* reduces to a
# shareable, declarative spec: (class_name => [{name:, type:, macro:}]).
#
# On `:destroy`, for each captured dependent association the transport calls
# `record.association(name).handle_dependency` — the exact method the original
# lambda invoked — so `:destroy` / `:delete` / `:nullify` / `:restrict_*` all
# dispatch correctly (that dispatch lives in AR's handle_dependency).
#
# Source shape (frozen into SHAREABLE_DEPENDENT_ASSOCIATIONS):
#   { class_name(String) => [ {name: Symbol, type: Symbol, macro: Symbol}, … ] }
#
# Keyed by class *name* (not object_id) because `dependent:` replay looks up the
# record's own class, not its ancestors (a class only cascades the associations
# it itself declared).

module RactorRailsShim
  module Callbacks
    class DependentAssociationTransport
      # source: a Hash { class_name => [entry, …] } as described above, OR a
      # callable returning that Hash (resolves the shareable constant lazily at
      # replay time in a worker).
      def initialize(source:)
        @source = source
      end

      def source
        s = @source
        return s.call if s.respond_to?(:call)
        return ::RactorRailsShim.const_get(s) if s.is_a?(::Symbol)
        s
      rescue StandardError
        nil
      end

      # This transport ONLY owns the `:destroy` kind. (The symbolic transport
      # also applies to :destroy for app before_destroy methods; both run.)
      def applies_to?(kind)
        kind == :destroy
      end

      # Re-drive every dependent association the record's class declared,
      # BEFORE the record itself is deleted (matching the before_destroy order).
      # Per-entry isolation: one failing association must not skip the others
      # (a swallowed failure here leaves orphaned children → FK violation on
      # the parent DELETE, so surface the reason on stderr before continuing).
      #
      # Entries are the UNION of (a) the main-Ractor-captured table and
      # (b) entries derived from the worker's OWN shareable `_reflections`.
      # The capture runs at an arbitrary boot point and in lazily-loaded
      # (test/non-eager) apps can miss app models entirely — the worker-side
      # derivation uses the same shareable reflections the worker already
      # reads for association lookups, so it is load-order independent.
      def before(context, kind)
        return unless kind == :destroy
        entries = entries_for(context)
        if entries.empty?
          warn "ractor-rails-shim: dependent cascade: no entries for " \
               "#{class_name_of(context).inspect} (table=#{source.inspect[0, 200]})"
          return
        end
        entries.each do |entry|
          assoc = association_of(context, entry[:name])
          next unless assoc && assoc.respond_to?(:handle_dependency)
          begin
            assoc.handle_dependency
          rescue StandardError => e
            warn "ractor-rails-shim: dependent cascade #{context.class.name}##{entry[:name]} " \
                 "failed (#{e.class}: #{e.message[0, 160]})"
          end
        end
      end

      # After: nothing — dependent cascades are a before_destroy concern.
      def after(_context, _kind)
        nil
      end

      private

      # Captured-table entries + worker-derived entries, deduped by name.
      def entries_for(context)
        seen = {}
        (captured_entries(context) + derived_entries(context)).each do |entry|
          seen[entry[:name]] = entry
        end
        seen.values
      end

      def captured_entries(context)
        table_entries = source
        (table_entries && table_entries[class_name_of(context)]) || []
      rescue StandardError
        []
      end

      # Derive [{name:, type:, macro:}] from the record class's OWN
      # `_reflections` — the same shareable hash workers read for association
      # lookups (via the class-attribute fallback chain), so no unshareable
      # state is touched.
      def derived_entries(context)
        klass = context.class
        reflections = klass._reflections
        return [] unless reflections.is_a?(Hash)
        reflections.values.map do |refl|
          next unless refl.respond_to?(:options)
          dep = refl.options[:dependent]
          next unless dep
          {
            name: refl.name.to_sym,
            type: dep.to_sym,
            macro: refl.macro.to_sym,
          }
        end.compact
      rescue StandardError
        []
      end

      def class_name_of(context)
        klass = context.class
        klass.name if klass.respond_to?(:name)
      rescue StandardError
        nil
      end

      def association_of(context, name)
        context.association(name) if context.respond_to?(:association)
      rescue StandardError
        nil
      end
    end
  end
end