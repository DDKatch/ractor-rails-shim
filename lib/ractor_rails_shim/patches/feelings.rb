# frozen_string_literal: true

# Patch the feelings gem's module-singleton state for worker Ractors.
#
# Three lazily-initialized module ivars on `Feelings` (`lib/feelings.rb`):
#
#   * `@judge` (`judge` / `judge=`) — the decision-model judge wrapping an
#     external API client. Lazily built on first question: the builder RUNS
#     in whatever Ractor first asks → module-ivar write off-main →
#     IsolationError. Fix: per-Ractor judges via ::RactorRailsShim.storage
#     (each worker builds its own client). Main keeps its own. `judge=`
#     (boot configuration) also lands in the caller's storage; the
#     Thread.current override (`with_judge` / `current_judge`) already is
#     Ractor-local and stays untouched.
#
#   * `@random` (`random` / `random=`) — a Proc (`-> { Kernel.rand }`) stored
#     in a module ivar; per-request call `Feelings.random.call`. The ivar
#     write raises off-main, and even the default Proc object is per-Ractor
#     bound. Fix: workers build their own lambda per Ractor via storage.
#
#   * `@registry` (`registry` / `[]` / `load` / `register`) — the label-set
#     store, populated at boot (railtie `Feelings.load`) and read per
#     request. The Registry INSTANCE is un-shareable (mutable @data), so the
#     worker can never read the module ivar. Fix: workers get a fresh
#     `Registry` per Ractor; the boot-loaded data is re-registered into it
#     from a captured shareable snapshot when one exists. The capture runs
#     on the FIRST load/register call in main (replaced by the intercepted
#     `load`/`register`), storing a frozen copy of `registry.to_h`.
#     Workers without a captured snapshot get an empty registry (labels
#     resolve to their fallbacks) instead of raising.

module RactorRailsShim
  class << self
    def _install_feelings_patch
      return if @feelings_patched
      @feelings_patched = true
      _register_patch :feelings, "8.1"
      return unless defined?(::Feelings)

      _install_feelings_state
      _install_feelings_registry_capture
    end

    private

    def _install_feelings_state
      ::Feelings.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def judge
          key = :ractor_rails_shim_feelings_judge
          v = ::RactorRailsShim.storage[key]
          return v unless v.nil?
          if ::RactorRailsShim.storage.key?(key)
            return nil
          end
          judge = ::Feelings::Judges::DecisionModel.new(::RubyDecisionModel.client)
          ::RactorRailsShim.storage[key] = judge
          judge
        end

        def judge=(judge)
          ::RactorRailsShim.storage[:ractor_rails_shim_feelings_judge] = judge
          ::RactorRailsShim.storage[:ractor_rails_shim_feelings_judge_set] = true
        end

        def random
          key = :ractor_rails_shim_feelings_random
          v = ::RactorRailsShim.storage[key]
          return v unless v.nil?
          return nil if ::RactorRailsShim.storage.key?(key)
          random = -> { Kernel.rand }
          ::RactorRailsShim.storage[key] = random
          random
        end

        def random=(source)
          ::RactorRailsShim.storage[:ractor_rails_shim_feelings_random] = source
          ::RactorRailsShim.storage[:ractor_rails_shim_feelings_random_set] = true
        end

        def reset!
          ::RactorRailsShim.storage.delete(:ractor_rails_shim_feelings_judge)
          ::RactorRailsShim.storage.delete(:ractor_rails_shim_feelings_judge_set)
          ::RactorRailsShim.storage.delete(:ractor_rails_shim_feelings_random)
          ::RactorRailsShim.storage.delete(:ractor_rails_shim_feelings_random_set)
          ::RactorRailsShim.storage[:ractor_rails_shim_feelings_registry] = nil
          self
        end
      RUBY
    end

    def _install_feelings_registry_capture
      ::Feelings.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        alias_method :_shim_original_load, :load
        def load(path)
          result = _shim_original_load(path)
          ::RactorRailsShim._capture_feelings_registry!
          result
        end

        alias_method :_shim_original_register, :register
        def register(hash)
          result = _shim_original_register(hash)
          ::RactorRailsShim._capture_feelings_registry!
          result
        end

        def registry
          key = :ractor_rails_shim_feelings_registry
          v = ::RactorRailsShim.storage[key]
          return v unless v.nil?
          return Feelings::Registry.new if ::RactorRailsShim.storage.key?(key)
          registry = ::Feelings::Registry.new
          snapshot = begin
            ::RactorRailsShim::FEELINGS_REGISTRY_SNAPSHOT
          rescue ::NameError
            nil
          end
          registry.register(snapshot) if snapshot.is_a?(Hash)
          ::RactorRailsShim.storage[key] = registry
          registry
        end
      RUBY
    end

    def _capture_feelings_registry!
      return unless ::Ractor.main?
      registry = ::Feelings.instance_variable_get(:@registry)
      return unless registry.is_a?(::Feelings::Registry)
      snapshot = ::Ractor.make_shareable(registry.to_h) rescue nil
      return unless snapshot
      _reassign_shareable_const(:FEELINGS_REGISTRY_SNAPSHOT, snapshot)
    end
  end
end
