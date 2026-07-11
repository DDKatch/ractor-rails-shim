# frozen_string_literal: true

# Make Rails' named-route `_routes` accessors Ractor-safe.
#
# `ActionDispatch::Routing::RouteSet#url_helpers` (actionpack
# action_dispatch/routing/route_set.rb) builds an anonymous module that, when
# included into a controller or view base, defines two `_routes` accessors
# with BLOCKS that capture the main Ractor's `routes`:
#
#   included do
#     redefine_singleton_method(:_routes) { routes }   # singleton (class) method
#   end
#   define_method(:_routes) { @_routes || routes }     # instance method
#
# Both blocks are compiled in the main Ractor. Calling either from a worker
# Ractor raises "defined with an un-shareable Proc in a different Ractor".
# The singleton one is what ActionView's `build_view_context_class`
# (action_view/rendering.rb:85) reads to decide whether to mix in
# `url_helpers` — when it raises, the `if routes` guard is skipped and every
# named route helper (new_post_path, etc.) is missing in workers. The
# instance one is what `url_for` / the helpers' `method_missing` calls.
#
# Fix: intercept the `define_method(:_routes, &block)` calls — `redefine_
# singleton_method` ultimately delegates to `define_method` (see
# active_support/core_ext/module/redefine_method.rb), so overriding
# `define_method` covers BOTH the singleton and instance accessors — and
# replace the block body with a string-eval'd method that returns the
# shareable RouteSet via `Rails.application.routes` (Rails is available in
# every Ractor; the returned RouteSet is readable from workers — verified).
# No captured binding, so the methods are callable from any Ractor.
# Behaviour is identical in the main Ractor. Every other `define_method` call
# passes through the (aliased) original.
#
# NOTE: we capture the original with `alias_method` rather than `super`,
# because defining `def define_method` on `Module` *replaces* the core
# method, leaving `super` with no chain (Module's parent Object has no
# `define_method`).

module RactorRailsShim
  class << self
    def install_url_helpers_patch
      return if @url_helpers_patched
      @url_helpers_patched = true
      _register_patch :url_helpers, "8.1"
      return unless defined?(::Module)

      ::Module.class_eval do
        alias_method :_rrs_orig_define_method, :define_method
        def define_method(name, *args, &block)
          if name == :_routes && block
            class_eval "def _routes; @_routes || ::Rails.application.routes; end"
          else
            _rrs_orig_define_method(name, *args, &block)
          end
        end
      end
    end
  end
end
