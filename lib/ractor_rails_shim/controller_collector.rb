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
# until Issue #31 removes it. `_swallow` is a collaborator reached
# through the facade; Issue #23 will inject it as a constructor arg.
#
# NOTE: this method is currently not called from any lib/ path (the
# declaration-time `CallbackCapture` flow replaced the older post-hoc
# `_capture_controller_callbacks!` that called it). It's kept as a
# diagnostic/utility and extracted here to get it out of the god module.
# If a future need wires it back in (e.g. a routes-only diagnostic), the
# role object is the call site.

module RactorRailsShim
  module ControllerCollector
    # Collect the set of loaded controller classes from `app`'s routes
    # table and `ApplicationController.descendants`. Best-effort: each
    # branch is funneled through `_swallow`. Returns a compacted, uniq
    # Array of controller classes (may be empty).
    def self.call(app)
      classes = []
      RactorRailsShim._swallow("collect controller classes") do
        router = (app.respond_to?(:routes) ? app.routes : nil) ||
                 (defined?(::Rails) && ::Rails.application && ::Rails.application.routes)
        router.routes.each do |r|
          c = r.defaults[:controller] rescue nil
          next unless c && c.respond_to?(:camelize)
          klass = "#{c.camelize}Controller".safe_constantize rescue nil
          classes << klass if klass
        end
      end
      RactorRailsShim._swallow("collect controller classes (descendants)") do
        if defined?(::ApplicationController) && ::ApplicationController.respond_to?(:descendants)
          classes.concat(::ApplicationController.descendants)
        end
      end
      classes.compact.uniq
    end
  end
end