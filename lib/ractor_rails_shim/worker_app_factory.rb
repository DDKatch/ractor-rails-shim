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
    @autoloaders = nil
    @const_get_callable = nil
    @worker_app_class = nil

    def self.configure(autoloaders: nil, const_get: nil, worker_app_class: nil)
      @autoloaders = autoloaders
      @const_get_callable = const_get
      @worker_app_class = worker_app_class
    end

    def self.reset_configuration
      @autoloaders = nil
      @const_get_callable = nil
      @worker_app_class = nil
    end

    def self.autoloaders
      @autoloaders
    end

    def self.const_get_callable
      @const_get_callable
    end

    def self.worker_app_class
      @worker_app_class || WorkerApp
    end

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
      al = autoloaders
      cget = const_get_callable || Object.method(:const_get)
      if al.nil?
        # Backward compat: fall back to Rails.autoloaders when no explicit
        # autoloaders injected (seam not yet called).
        if defined?(::Rails) && Rails.respond_to?(:autoloaders)
          al = Rails.autoloaders
        else
          return map.freeze
        end
      end
      loaders =
        if al.respond_to?(:main) && al.respond_to?(:once)
          [al.main, al.once]
        elsif al.respond_to?(:each)
          al.to_a
        else
          []
        end
      loaders.each do |loader|
        next unless loader && loader.respond_to?(:all_expected_cpaths)
        begin
          loader.all_expected_cpaths.values.each do |cpath|
            obj = cget.call(cpath) rescue next
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
      wa = worker_app_class.new(frozen_app, bindings)
      wa.freeze
      Ractor.make_shareable(wa)
    end
  end
end