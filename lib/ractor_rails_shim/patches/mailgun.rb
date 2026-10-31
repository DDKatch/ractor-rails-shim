# frozen_string_literal: true

# Patch Mailgun's module-level config for worker Ractors.
#
# `Mailgun` holds its configuration in EIGHT module ivars
# (`lib/mailgun.rb:48-58`: `class << self; attr_accessor :api_host, :api_key,
# :api_version, :protocol, :mailgun_host, :proxy_url, :test_mode, :domain`),
# written by the app's `Mailgun.configure { ... }` initializer.
#
# Runtime hazard: `Mailgun::Client.new` / `Mailgun::Address.new` use the
# accessors as their default argument values on EVERY client construction
# (`lib/mailgun/client.rb:12-18`). A worker Ractor reading a module ivar
# holding an unfrozen String raises Ractor::IsolationError — so even a plain
# `Mailgun::Client.new` from a worker fails.
#
# Fix: register all eight ivars in the SHAREABLE_CLASS_IVARS registry.
# At freeze time (prepare_for_ractors! / make_app_shareable!) the
# ShareableClassIvarFreezer deep-freezes each configured value IN PLACE, so
# the very same accessors return shareable values in workers — no reader or
# writer surgery, and `Mailgun::Client` instances (already per-Ractor: each
# builds its own Faraday connection) work unchanged.
#
# Values the app never configured stay nil (worker reads of an undefined
# module ivar are safe; the Freezer skips nil entries).

module RactorRailsShim
  MAILGUN_CONFIG_IVARS = %i[
    @api_host @api_key @api_version @protocol
    @mailgun_host @proxy_url @test_mode @domain
  ].freeze

  SHAREABLE_CLASS_IVARS.concat(MAILGUN_CONFIG_IVARS.map { |ivar| ["Mailgun", ivar] })

  class << self
    def _install_mailgun_patch
      return if @mailgun_patched
      @mailgun_patched = true
      _register_patch :mailgun_config, "8.1"
      return unless defined?(::Mailgun)
      # Apply now in case Mailgun.configure already ran at install time;
      # the freeze-time pass (prepare_for_ractors!) re-freezes whatever the
      # app configured afterwards.
      ShareableClassIvarFreezer.call
    end
  end
end
