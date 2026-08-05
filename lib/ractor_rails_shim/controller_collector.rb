# frozen_string_literal: true

# `RactorRailsShim::ControllerCollector` — the role object that collects
# the set of loaded controller classes from the app's routes table and
# `ApplicationController.descendants` (extracted from the facade god
# module in Step 22.4, Issue #22; POODR §1 SRP).
#
# Two branches, each funneled through `_swallow` so a failure in one
# doesn't prevent the other from running:
#   1. routes walk — `app.routes.each { |r| r.defaults[:controller] }`,
#      camelize + safe_constantize the class name.
#   2. descendants — `ApplicationController.descendants` if defined.
# Returns `compact.uniq` so duplicate references dedup.
#
# The facade method `_collect_controller_classes` delegates to `.call`
# until Issue #31 removes it. `_swallow` is a collaborator reached via
# the `funnel` seam. The default is the facade lookup
# (`RactorRailsShim::Funnel.method(:swallow)`) so existing call sites keep
# working; `configure(funnel:)` injects a different funnel so the role
# is independently constructible and specable without the
# `RactorRailsShim` god module loaded (Issue #23, POODR §2 Dependencies).
#
# NOTE: this method is currently not called from any lib/ path (the
# declaration-time `CallbackCapture` flow replaced the older post-hoc
# `_capture_controller_callbacks!` that called it). It's kept as a
# diagnostic/utility and extracted here to get it out of the god module.
# If a future need wires it back in (e.g. a routes-only diagnostic), the
# role object is the call site.

module RactorRailsShim
  module ControllerCollector
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
    # facade lookup (`RactorRailsShim::Funnel.method(:swallow)`).
    def self.funnel
      @funnel || RactorRailsShim::Funnel.method(:swallow)
    end

    # Collect the set of loaded controller classes from `app`'s routes
    # table and `ApplicationController.descendants`. Best-effort: each
    # branch is funneled through `funnel`. Returns a compacted, uniq
    # Array of controller classes (may be empty).
    def self.call(app)
      classes = []
      funnel.call("collect controller classes") do
        router = (app.respond_to?(:routes) ? app.routes : nil) ||
                 (defined?(::Rails) && ::Rails.application && ::Rails.application.routes)
        router.routes.each do |r|
          c = r.defaults[:controller] rescue nil
          next unless c && c.respond_to?(:camelize)
          klass = "#{c.camelize}Controller".safe_constantize rescue nil
          classes << klass if klass
        end
      end
      funnel.call("collect controller classes (descendants)") do
        if defined?(::ApplicationController) && ::ApplicationController.respond_to?(:descendants)
          classes.concat(::ApplicationController.descendants)
        end
      end
      classes.compact.uniq
    end
  end
end