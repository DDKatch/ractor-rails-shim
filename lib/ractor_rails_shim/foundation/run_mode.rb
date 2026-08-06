# frozen_string_literal: true

# RunMode: the thread-mode vs Ractor-mode configuration decision.
#
# Extracted from the RactorRailsShim singleton (`core.rb`) per POODR: deciding
# which mode the shim runs in is a *configuration* responsibility, distinct
# from the install orchestration that consumes the decision. The decision
# used to be a side effect buried inside `install` (reading `ENV["SERVER"]`
# into `@thread_mode`), which made install non-deterministic based on ambient
# ENV with no visible configuration surface. RunMode owns that decision so it
# is independently specable and configurable:
#
#   RactorRailsShim::RunMode.thread = true        # explicit
#   RactorRailsShim::RunMode.detect_from_env       # ENV-based (pure query)
#   RactorRailsShim::RunMode.resolve!              # install-time: explicit,
#                                                  # else fall back to ENV
#   RactorRailsShim::RunMode.thread?               # the answer
#   RactorRailsShim::RunMode.reset                 # test/teardown helper
#
# The RactorRailsShim facade keeps `thread_mode?` / `thread_mode=` delegates
# so existing call sites (patches/class_attribute.rb, patches/active_support.rb,
# specs that set `RactorRailsShim.thread_mode = true`) keep working unchanged.
module RactorRailsShim
  module RunMode
    # SERVER values that select thread-server (Puma/Falcon/Thin/Webrick) mode
    # instead of the default Ractor mode. Matched case-insensitively. Kept as a
    # Regex to mirror the original `core.rb:189` predicate exactly.
    THREAD_SERVER_RE = /puma|falcon|thin|webrick|thread/i.freeze

    class << self
      # The resolved mode: true for thread-server mode, false for Ractor mode.
      # Defaults to false when never configured. After `resolve!` or an
      # explicit `thread=`, this is sticky — ENV no longer affects it.
      def thread?
        return @thread if defined?(@thread)
        false
      end

      # Explicitly set the mode. Once called, `resolve!` becomes a no-op:
      # explicit configuration wins over ambient ENV. This mirrors the old
      # `install` body's `unless defined?(@thread_mode)` guard, lifted into
      # the object that owns the state.
      def thread=(value)
        @thread = !!value
      end

      # Pure query of the ambient ENV["SERVER"]. Returns true when the server
      # name matches a known thread server (puma|falcon|thin|webrick|thread*),
      # case-insensitively; false otherwise (including when SERVER is unset or
      # empty). Has no side effects and does not mutate RunMode state — call
      # `resolve!` to fold the ENV answer into the resolved mode.
      def detect_from_env
        server = ENV["SERVER"]
        return false unless server
        !!(server =~ THREAD_SERVER_RE)
      end

      # The install-time decision. If the mode has already been set explicitly
      # (via `thread=`), keep it — explicit wins over ENV. Otherwise, detect
      # from ENV and freeze that as the resolved mode. Idempotent: a second
      # call is a no-op because the first call (or an explicit `thread=`)
      # defined `@thread`.
      def resolve!
        return if defined?(@thread)
        @thread = detect_from_env
        @thread
      end

      # Reset to the unconfigured state. For specs and teardown; not part of
      # the public install contract.
      def reset
        remove_instance_variable(:@thread) if defined?(@thread)
      end
    end
  end
end