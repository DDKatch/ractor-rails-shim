# frozen_string_literal: true

# Upstream-suite hook, loaded via RUBYOPT (-r<this file>) before the gem's
# suite starts.
#
# IMPORTANT: this file must stay stdlib-only. RUBYOPT also runs inside the
# `bundle` CLI process, BEFORE Bundler.setup — requiring any gem there goes
# through the ambient gemset, not the bundle, and breaks `bundle exec`.
#
# So: nothing is required here. A Kernel#require hook waits for the target
# gem's root constant to become defined (the gem's own require runs inside
# the bundle, after bundler/setup), and only then loads the shim in-bundle
# and dispatches the framework patches.
#
# Config via ENV:
#   SHIM_DISPATCH_WHEN   comma-separated root constants, e.g. "I18n" or
#                        "Rack,Puma". Omit = no-op (harness may pass nothing
#                        for gems that need no framework dispatch).

module ShimUpstreamDispatch
  TARGETS = (ENV["SHIM_DISPATCH_WHEN"] || "").split(",").map(&:strip).freeze
  # Root constants (first segment of each target path) trigger the shim
  # load. Full paths (incl. autoloaded constants) are the late dispatch
  # file's job — see upstream/run.rb.
  ROOTS = TARGETS.map { |t| t.split("::").first }.uniq.freeze
  class << self
    def ensure_shim!
      return if @shim_loaded
      @shim_loaded = true
      require "ractor_rails_shim"
      RactorRailsShim.install
    end

    def maybe_load!
      return if @shim_loaded
      return unless ROOTS.any? { |t| Object.const_defined?(t) }
      ensure_shim!
    end
  end
  @shim_loaded = false

  module Kernel
    def require_with_shim_dispatch(name)
      require_without_shim_dispatch(name)
      ShimUpstreamDispatch.maybe_load!
    end
    alias_method :require_without_shim_dispatch, :require
    alias_method :require, :require_with_shim_dispatch
  end

  # The target may already be defined (prelude required late).
  maybe_load!
end
