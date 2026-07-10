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
    def _install_devise_url_helpers_patch
      return if @devise_url_helpers_patched
      @devise_url_helpers_patched = true
      _register_patch :devise_url_helpers, "5.0"
      return unless defined?(::Devise::Controllers::UrlHelpers)

      mod = ::Devise::Controllers::UrlHelpers

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

      # Patch Devise.mappings: workers return the shareable snapshot (no
      # class-variable read, no route reload). Main keeps original behavior.
      # NOTE: the original reads `@@mappings` — but a class variable referenced
      # inside a `module_eval` string resolves to the LEXICAL module (here
      # RactorRailsShim), not Devise (anti-pattern #5 in the playbook). Read it
      # explicitly via class_variable_get so both ractors hit Devise's real
      # class variable.
      if defined?(::Devise) && ::Devise.respond_to?(:mappings)
        ::Devise.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def mappings
            return RactorRailsShim::DEVISE_MAPPINGS if !Ractor.main? && RactorRailsShim.const_defined?(:DEVISE_MAPPINGS)
            Rails.application.try(:reload_routes_unless_loaded)
            ::Devise.class_variable_get(:@@mappings)
          end
        RUBY
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
