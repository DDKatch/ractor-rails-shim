# frozen_string_literal: true

# WorkerAppFactory: the shareable-Rack-app factory role extracted from the
# RactorRailsShim god module (Issue #13, Step 13.4; POODR §1 SRP).
#
# Owns:
#   - capture_constants!  capture the app's Zeitwerk constant name → object
#                         map (run in main, travels to workers so bare
#                         `Post` etc. resolve)
#   - build(frozen_app)   wrap the frozen, shareable app in a WorkerApp,
#                         freeze + make_shareable, return the shareable
#                         instance handed to `Ractor.new(app) { |a| ... }`
#
# `WorkerApp` lives in `ractor_rails_shim/worker_app.rb` (moved out of
# core.rb by the same step). The RactorRailsShim singleton keeps facade
# methods (`capture_app_constants!`, `worker_app!`) that delegate, so
# worker_app_spec, naming_convention_spec, and the integration spec keep
# passing unchanged.

require_relative "worker_app"

module RactorRailsShim
  module WorkerAppFactory
    # Capture a frozen name -> object map for every constant the
    # application's Zeitwerk loaders manage. Runs in the MAIN Ractor, after
    # eager load, where all app constants are defined. The map travels to
    # worker Ractors, which use it to (re)bind the constant *names* into
    # their own namespaces.
    #
    # Why this is needed: a Ractor boundary does NOT share top-level
    # constant *names* — only the class/module *objects* reachable from the
    # frozen shared app graph cross the boundary. A worker Ractor therefore
    # sees `RactorRailsShim`, `ActiveRecord`, `ApplicationRecord`, the
    # controllers, etc. (objects reachable from the app), but NOT the
    # application's own model constants (e.g. `Post`): the object is in the
    # graph, but its name is not bound in the worker, so
    # `PostsController#index`'s `Post` reference raises NameError. Rebinding
    # the captured names fixes it without re-running autoloading (which is
    # itself impossible in a worker, since `Zeitwerk::Loader.new` raises
    # IsolationError off the main Ractor).
    def self.capture_constants!
      map = {}
      unless defined?(::Rails) && Rails.respond_to?(:autoloaders)
        return map.freeze
      end
      autoloaders = Rails.autoloaders
      # Guard against non-Zeitwerk configurations: Rails.autoloaders may be
      # present (the method exists) but not expose `main`/`once` (e.g.
      # classic loader mode, or `config.autoloaders = false` returning a
      # null object). `main`/`once` may also individually be nil when only
      # one loader is configured. Filter to the loaders that actually
      # expose `all_expected_cpaths` (the Zeitwerk introspection API the
      # capture relies on).
      loaders =
        if autoloaders.respond_to?(:main) && autoloaders.respond_to?(:once)
          [autoloaders.main, autoloaders.once]
        elsif autoloaders.respond_to?(:each)
          autoloaders.to_a
        else
          []
        end
      loaders.each do |loader|
        next unless loader && loader.respond_to?(:all_expected_cpaths)
        begin
          loader.all_expected_cpaths.values.each do |cpath|
            obj = Object.const_get(cpath) rescue next
            begin
              Ractor.make_shareable(obj) unless Ractor.shareable?(obj)
            rescue StandardError
              next
            end
            map[cpath] = obj if Ractor.shareable?(obj)
          end
        rescue StandardError => e
          warn "[ractor_rails_shim] capture_app_constants!: #{e.class}: #{e.message}"
        end
      end
      map.freeze
    end

    # Build the shareable Rack app handed to kino. Captures the
    # application's constants in the main Ractor and wraps the frozen,
    # shareable app in a WorkerApp that rebinds those constants (and
    # initializes the worker's ActiveRecord connection) on the first
    # request served by each worker Ractor. Returns a shareable WorkerApp
    # instance — frozen and `Ractor.make_shareable`'d — so it can be passed
    # directly to `Ractor.new(WorkerAppFactory.build(app)) { |a| a.call(env) }`
    # without the caller having to know the shareability contract.
    def self.build(frozen_app)
      bindings = capture_constants!
      wa = WorkerApp.new(frozen_app, bindings)
      wa.freeze
      # Ractor.make_shareable returns the shareable object, so this is the
      # factory's return value.
      Ractor.make_shareable(wa)
    end
  end
end