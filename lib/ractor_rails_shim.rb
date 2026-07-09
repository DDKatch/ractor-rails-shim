# frozen_string_literal: true

require_relative "ractor_rails_shim/version"
require_relative "ractor_rails_shim/patches"
require_relative "ractor_rails_shim/check"

# A monkey-patch shim that reroutes Rails' class-level instance variable
# accessors (Rails.application, Rails.cache, Rails.logger, mattr_accessor,
# etc.) through ActiveSupport::IsolatedExecutionState, which is
# Ractor-safe (thread-local; each Ractor has its own threads).
#
# This lets a Rails app run in Ractor mode without forking Rails itself.
# Each Ractor gets its own copy of the globals (same shape as forking one
# process per core, but without heap duplication). For shareable state
# (frozen config, route tables) use Ractor.make_shareable + a constant
# instead — that shares one copy by reference, zero copy.
#
# Stopgap: the goal is for Rails to do this upstream. When it does, this
# shim becomes a no-op and can be removed from your Gemfile.
module RactorRailsShim
  class << self
    # Require this gem and the patches auto-install IF Rails is loaded.
    # If Rails isn't loaded yet, install is deferred to the first call
    # of `install` (call it from config/boot.rb before Rails.application).
    def autoload_install!
      install if defined?(::Rails) && !installed?
    end
  end
end

# Auto-install if Rails is already loaded (e.g. via Bundler.require in a
# console). If not, the user calls RactorRailsShim.install from boot.
RactorRailsShim.autoload_install!