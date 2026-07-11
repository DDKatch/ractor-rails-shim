# frozen_string_literal: true

# Make Rails' URL generation Ractor-safe.
#
# Two distinct problems exist in Rails' URL helpers under a frozen, shared
# (Ractor) graph:
#
# 1. Named route helpers, `_routes`, and `_generate_paths_by_default` are all
#    defined with `define_method(&block)` / `redefine_method(&block)`, so their
#    bodies are Procs created in the *main* Ractor. Any worker that calls them
#    raises "defined with an un-shareable Proc in a different Ractor".
#
# 2. `RouteSet::PATH` / `RouteSet::UNKNOWN` are lambdas used as the
#    `url_strategy` callable inside every helper; calling them from a worker is
#    also un-shareable.
#
# These are addressed in `route_helpers.rb` (run *before* routes are drawn):
# the helper methods are regenerated as compiled `def`s and `PATH`/`UNKNOWN`
# are replaced with shareable `Method` objects.
#
# This file adds a defensive safety net: if any residual un-shareable error
# slips through, we re-dispatch the same call from this shim-defined method
# (whose scope is the worker's own Ractor).

module RactorRailsShim
  class << self
    def install_url_helpers_patch
      return if @url_helpers_patched
      @url_helpers_patched = true
      _register_patch :url_helpers, "8.1"
      return unless defined?(::ActiveRecord::Base)

      if defined?(::ActionView::RoutingUrlFor)
        ::ActionView::RoutingUrlFor.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          alias_method :_rrs_orig_view_url_for, :url_for
          def url_for(options = nil)
            _rrs_orig_view_url_for(options)
          rescue => e
            raise unless e.message.include?("un-shareable Proc")
            if options.is_a?(Hash) || options.is_a?(ActionController::Parameters)
              full_url_for(options)
            else
              meth = _generate_paths_by_default ? :path : :url
              builder = ActionDispatch::Routing::PolymorphicRoutes::HelperMethodBuilder.public_send(meth)
              builder.handle_model_call(self, options)
            end
          end
        RUBY
      end

      if defined?(::ActionDispatch::Routing::UrlFor)
        ::ActionDispatch::Routing::UrlFor.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          alias_method :_rrs_orig_full_url_for, :full_url_for
          def full_url_for(options = nil)
            _rrs_orig_full_url_for(options)
          rescue => e
            raise unless e.message.include?("un-shareable Proc")
            if options.is_a?(Hash) || options.is_a?(ActionController::Parameters)
              route_name = options.delete :use_route
              merged = options.to_h.symbolize_keys.reverse_merge!(url_options)
              _routes.url_for(merged, route_name)
            else
              builder = ActionDispatch::Routing::PolymorphicRoutes::HelperMethodBuilder.url
              builder.handle_model_call(self, options)
            end
          end
        RUBY
      end
    end
  end
end
