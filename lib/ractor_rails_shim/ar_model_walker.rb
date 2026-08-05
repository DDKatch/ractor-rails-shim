# frozen_string_literal: true

# ARModelWalker — extracted role object (Issue #16, POODR §6 Modules & Roles).
#
# Four call sites independently enumerated
#   `[ActiveRecord::Base] + (ActiveRecord::Base.descendants rescue [])`
# with slightly different per-class guards and error handling:
#
#   - Freezers::CacheWarmer.call        (freezers.rb)  skips abstract classes
#   - Freezers::ClassIvarFreezer.call   (freezers.rb)  does NOT skip abstract
#   - ShareabilityTraversal.generate_ar_attribute_methods!   rescue StandardError
#   - ShareabilityTraversal.warm_attribute_method_patterns! rescue StandardError
#
# ARModelWalker centralizes the walk so the iteration contract is specable
# in one place and the four consumers express only their per-class work.
# The role:
#   - no-ops (yields nothing, returns 0) when ActiveRecord::Base is undefined
#   - yields Base itself, then each element of `descendants` (rescued to [])
#   - rescues per-class failures via `RactorRailsShim._swallow` so one bad
#     model does not abort the walk
#   - honors a `skip_abstract:` keyword for callers that must skip abstract
#     classes; default is to yield them (ClassIvarFreezer must NOT skip)
#   - returns the count of yielded models
#
# `_swallow` is reached via the `funnel` collaborator. The default is the
# facade lookup (`RactorRailsShim.method(:_swallow)`) so existing call
# sites keep working; `configure(funnel:)` injects a different funnel so
# the role is independently constructible and specable without the
# `RactorRailsShim` god module loaded (Issue #23, POODR §2 Dependencies).
module RactorRailsShim
  module ARModelWalker
    @funnel = nil

    # Inject the `funnel` collaborator — a callable responding to
    # `call(label) { block }` that runs the block and rescues
    # StandardError (matching `_swallow`). Passing `nil` (or calling
    # `reset_configuration`) restores the facade-lookup default.
    def self.configure(funnel:)
      @funnel = funnel
    end

    # Restore the default (facade-lookup) funnel. Test seam.
    def self.reset_configuration
      @funnel = nil
    end

    # The active funnel: the injected one if configured, else the
    # facade lookup (`RactorRailsShim.method(:_swallow)`).
    def self.funnel
      @funnel || RactorRailsShim.method(:_swallow)
    end

    # Iterate every loaded ActiveRecord model — Base itself plus its
    # descendants — yielding each to the block exactly once. Per-class
    # failures are funneled through `funnel` so the walk continues past
    # one bad model.
    #
    # Options:
    #   skip_abstract: true  — skip classes whose `abstract_class?` is true
    #                          (used by CacheWarmer, which only warms
    #                          concrete models). Default false so
    #                          ClassIvarFreezer and the attribute-method
    #                          warmers still visit abstract classes
    #                          (workers recurse into them).
    #
    # Returns the count of yielded models (0 when AR is absent).
    def self.each_model(skip_abstract: false)
      return 0 unless defined?(::ActiveRecord::Base)

      base = ::ActiveRecord::Base
      descendants =
        begin
          base.descendants
        rescue StandardError
          []
        end

      count = 0
      ([base] + descendants).each do |klass|
        next if skip_abstract && klass.respond_to?(:abstract_class?) && klass.abstract_class?
        begin
          yield klass
        rescue StandardError => e
          funnel.call("ARModelWalker #{klass}") { raise e }
        end
        count += 1
      end
      count
    end
  end
end