# frozen_string_literal: true

# Patch for Devise (5.0). Two blockers for worker Ractors:
#
# 1. Devise::Controllers::UrlHelpers#generate_helpers! defines every helper
#    (session_path, new_session_path, user_password_path, ...) via
#    `define_method method do |resource_or_scope, *args| ... end` — a block
#    that captures the MAIN ractor's binding. Calling `session_path(...)` from
#    a worker raises "defined with an un-shareable Proc in a different Ractor".
#    Fix: redefine each helper via string eval (no captured binding); the body
#    replicates the original exactly, delegating to the underlying Rails route
#    helper via `context.send(method, *args)` (the real helpers are already
#    patched in action_dispatch.rb).
#
# 2. The helper body (and Devise::Mapping.find_scope!) reads `Devise.mappings`,
#    which reads the `@@mappings` class variable — unreadable from a worker
#    Ractor. Fix: snapshot `Devise.mappings` as a shareable Hash at prepare
#    time and have the patched `Devise.mappings` reader return it in workers
#    (skipping the main-ractor route reload).

module RactorRailsShim
  class << self
    # Devise::FailureApp.call memoizes its Rack endpoint in a class-level ivar
    # (`@respond ||= action(:respond)`). A worker Ractor cannot set instance
    # variables on a shared class/module, so calling it raises "can not set
    # instance variables of classes/modules by non-main Ractors". Route the
    # memoized endpoint through IsolatedExecutionState (per-Ractor), so each
    # worker builds and caches its own copy without mutating the shared class.
    def _install_devise_failure_app_patch
      return if @devise_failure_app_patched
      @devise_failure_app_patched = true
      _register_patch :devise_failure_app, "5.0"
      return unless defined?(::Devise::FailureApp)
      ::Devise::FailureApp.singleton_class.module_eval <<-'RUBY', __FILE__, __LINE__ + 1
        def call(env)
          respond = ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_devise_failure_respond] ||= action(:respond)
          respond.call(env)
        end
      RUBY
      # Devise::FailureApp#relative_url_root reads `config.action_controller
      # .try(:relative_url_root)`. `config.action_controller` is a
      # Rails::Railtie::Configuration whose `relative_url_root` is NOT a real
      # method, so `try` triggers `method_missing`, which reads the `@@options`
      # class variable — unreadable from a worker Ractor. `Rails.application
      # .config.relative_url_root` IS a real method on
      # Rails::Application::Configuration (no method_missing, no class var), so
      # use just that; for the common case (no relative root) it returns nil.
      if defined?(::Devise::FailureApp)
        ::Devise::FailureApp.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def relative_url_root
            @relative_url_root ||= Rails.application.config.relative_url_root
          end
        RUBY
      end
    end

    def _install_devise_url_helpers_patch
      return if @devise_url_helpers_patched
      @devise_url_helpers_patched = true
      _register_patch :devise_url_helpers, "5.0"
      return unless defined?(::Devise::Controllers::UrlHelpers)

      mod = ::Devise::Controllers::UrlHelpers

      # Patch Devise.mappings FIRST (before the snapshot below) so every
      # subsequent read — including the snapshot — does NOT trigger a route
      # reload. Routes are fully drawn by Rails.application.initialize! before
      # prepare_for_ractors! runs, so @@mappings is already populated in main;
      # workers read the shareable snapshot instead. The ORIGINAL
      # Devise.mappings calls reload_routes_unless_loaded, which during
      # prepare collapses the RouteSet to a single railtie route (rails/info)
      # that then gets frozen into the shared app graph — breaking routing for
      # every worker Ractor.
      if defined?(::Devise) && ::Devise.respond_to?(:mappings)
        ::Devise.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def mappings
            return RactorRailsShim::DEVISE_MAPPINGS if !Ractor.main? && RactorRailsShim.const_defined?(:DEVISE_MAPPINGS)
            ::Devise.class_variable_get(:@@mappings)
          end
        RUBY
      end

      # Capture a shareable snapshot of Devise.mappings in MAIN (after routes
      # are drawn). The real Mapping objects hold an unshareable failure-app
      # lambda and a default-proc Hash, so we can't share them directly; build
      # a DeviseMappingSnapshot per scope (see make_shareable.rb). Workers read
      # this via the patched Devise.mappings reader.
      if Ractor.main? && defined?(::Devise)
        begin
          h = ::Devise.mappings
          snap = {}
          h.each { |scope, mapping| snap[scope] = _devise_mapping_snapshot(mapping) }
          snap = Ractor.make_shareable(snap) rescue nil
          const_set(:DEVISE_MAPPINGS, snap) if snap
        rescue
          nil
        end
      end

      # Redefine each generated helper via string eval (no captured binding).
      # Replicate the EXACT body of Devise::Controllers::UrlHelpers.generate_helpers!
      # (lib/devise/controllers/url_helpers.rb): the helper does NOT call the
      # alias method on the context — it reconstructs the REAL route helper name
      # from `action` + `scope` + `module_name` (e.g. alias `session_path` ->
      # real `user_session_path`) and sends THAT to the context. Bake in
      # `action`/`module_name`/`path_or_url` as literals; `scope` is resolved
      # per-call from the argument, so interpolate it at runtime (\\#{scope}).
      routes = ::Devise::URL_HELPERS.slice(*(::Devise.mappings.values.map(&:used_helpers).flatten.uniq))
      routes.each do |module_name, actions|
        [:path, :url].each do |path_or_url|
          actions.each do |action|
            action_prefix = action ? "#{action}_" : ""
            method = :"#{action_prefix}#{module_name}_#{path_or_url}"
            mod.module_eval <<-RUBY, __FILE__, __LINE__ + 1
              def #{method}(resource_or_scope, *args)
                scope = Devise::Mapping.find_scope!(resource_or_scope)
                router_name = Devise.mappings[scope].router_name
                context = router_name ? send(router_name) : _devise_route_context
                context.send("#{action_prefix}\#{scope}_#{module_name}_#{path_or_url}", *args)
              end
            RUBY
          end
        end
      end
    end
  end
end
