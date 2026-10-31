# frozen_string_literal: true

# Patch the async-http constant surface (the gems that back the Falcon /
# async server stack the test project uses).
#
# async-http defines six mutable, non-frozen constants that are READ at
# runtime (per request / per connection):
#
#   lib/async/http/endpoint.rb            SCHEMES                 (scheme -> URI class, read by Endpoint.new)
#   lib/async/http/protocol/http2.rb      CLIENT_SETTINGS         (HTTP/2 client negotiation)
#   lib/async/http/protocol/http2.rb      SERVER_SETTINGS         (HTTP/2 server negotiation)
#   lib/async/http/protocol/http2/request.rb  NO_RESPONSE         (bogus 500 frames template)
#   lib/async/http/protocol/https.rb      HANDLERS                (ALPN handler table)
#   lib/async/http/middleware/location_redirector.rb  PROHIBITED_GET_HEADERS
#
# A worker Ractor reading an un-shareable (mutable) constant raises
# Ractor::IsolationError. All six hold plain data (frozen Strings/Integers +
# URI protocol classes), so deep-freezing via the shareable-constants
# pipeline is sufficient — no accessor surgery needed.
#
# The registration below is picked up by ConstantShareabilizer (applied at
# install, retried at prepare_for_ractors! for constants that load later).
# The install method only exists to register the patch in the version
# policy (the auto-discovery contract) and to force an early apply while
# Async::HTTP is already loaded.

module RactorRailsShim
  SHAREABLE_CONSTANTS.concat([
    "Async::HTTP::Endpoint::SCHEMES",
    "Async::HTTP::Protocol::HTTP2::CLIENT_SETTINGS",
    "Async::HTTP::Protocol::HTTP2::SERVER_SETTINGS",
    "Async::HTTP::Protocol::HTTP2::Request::NO_RESPONSE",
    "Async::HTTP::Protocol::HTTPS::HANDLERS",
    "Async::HTTP::Middleware::LocationRedirector::PROHIBITED_GET_HEADERS"
  ])

  class << self
    def _install_async_http_patch
      return if @async_http_patched
      @async_http_patched = true
      _register_patch :async_http_constants, "8.1"
      # Apply immediately when the constants already exist; the retry pass
      # in prepare_for_ractors! covers the late-loaded cases.
      return unless defined?(::Async::HTTP)
      ConstantShareabilizer.apply!
    end
  end
end
