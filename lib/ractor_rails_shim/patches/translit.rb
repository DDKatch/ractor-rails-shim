# frozen_string_literal: true

# Patch Translit's lazily-built conversion map.
#
# `Translit.russian` memoizes `@russian ||= create_russian_map` on the module
# singleton (`lib/translit.rb:54-55`). The first `Translit.convert!` inside a
# worker Ractor would try to WRITE the module ivar → IsolationError; even
# reading the unfrozen result Hash from a worker raises. The map is pure data
# (String keys, two-element String Arrays), so the fix is to pre-warm it in
# main at install time and deep-freeze it — the worker read of the frozen
# Hash (with frozen inner Arrays of frozen Strings) is then shareable and
# never triggers the `||=` write.
#
# `Translit.english` returns a fresh literal Hash on every call (no memo) and
# is only read from main (by `create_russian_map`), so it needs no patch.

module RactorRailsShim
  class << self
    def _install_translit_patch
      return if @translit_patched
      @translit_patched = true
      _register_patch :translit, "8.1"
      return unless defined?(::Translit) && ::Translit.respond_to?(:russian)

      return unless ::Ractor.main?
      map = ::Translit.russian
      frozen = map.each_with_object({}) do |(k, v), h|
        h[k] = v.map(&:freeze).freeze
      end.freeze
      ::Ractor.make_shareable(frozen)
      ::Translit.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        # No @russian write: module-ivar writes raise in worker Ractors. The
        # frozen map constant is the single source of truth.
        def russian
          ::RactorRailsShim::TRANSLIT_RUSSIAN_MAP
        end
      RUBY
      _reassign_shareable_const(:TRANSLIT_RUSSIAN_MAP, frozen)
    end
  end
end
