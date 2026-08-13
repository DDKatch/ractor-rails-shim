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
      def before(context, kind)
        return unless kind == :destroy
        table = source
        entries = table && table[class_name_of(context)]
        return unless entries
        entries.each do |entry|
          assoc = association_of(context, entry[:name])
          assoc.handle_dependency if assoc && assoc.respond_to?(:handle_dependency)
        end
      end

      # Dependent cascades are a before_destroy concern; nothing runs after.
      def after(_context, _kind)
        nil
      end

      private

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