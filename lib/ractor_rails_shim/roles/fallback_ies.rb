# frozen_string_literal: true

# Backward-compatibility alias for the former standalone fallback module.
#
# The `FallbackIES` module body moved to `RactorRailsShim::Storage::ThreadLocal`
# (Issue #14, Step 14.1). This file keeps the `RactorRailsShim::FallbackIES`
# constant reachable as an alias so existing references (and the
# `fallback_ies_spec` / `fallback_namespace_spec` contracts) resolve, without
# re-defining the methods.
#
# The namespace alias patch that USED to live here —
#   unless defined?(ActiveSupport::IsolatedExecutionState)
#     module ActiveSupport; IsolatedExecutionState = FallbackIES; end
#   end
# — is now dead code and has been removed (Issue #14, Step 14.3). No patch file
# references the literal `ActiveSupport::IsolatedExecutionState` anymore;
# they all route through `RactorRailsShim.storage`, which is set to
# `Storage::ThreadLocal` when AS is absent. Opening the ActiveSupport
# namespace from a third-party gem is therefore no longer necessary.

require_relative "../foundation/storage"

module RactorRailsShim
  FallbackIES = Storage::ThreadLocal
end