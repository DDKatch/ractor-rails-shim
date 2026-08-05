# frozen_string_literal: true

# VersionPolicy: the policy switch + patch-version registry.
#
# Version *detection* (reading runtime Ruby/Rails versions, segment
# extraction, satisfies?) lives in RactorRailsShim::Version. This module owns
# the orthogonal concern: what to *do* on a mismatch (the :warn/:strict/:off
# policy) and the registry mapping each install_* patch name to the Rails
# versions it was tested against. Extracted from the RactorRailsShim singleton
# (core.rb) so the policy is independently specable.
#
# Issue #37 (Round 4): the policy switch is a Strategy — three modules
# (Strict / Off / Warn) each implementing mismatch(message) and
# missing_ivar(obj, ivar, label, funnel:). The two `case policy when`
# switches (in VersionPolicy.mismatch and CallbackCapture.read_ivar_or_warn)
# are replaced by a single strategy lookup. POODR Ch.3 — remove the branch
# by extracting an object per branch.
module RactorRailsShim
  module VersionPolicy
    # Registry mapping each install_* patch name to the Rails version segments
    # it was developed and tested against. Populated by `register` (called by
    # each install_* method). To add 7.x support, write the version-specific
    # patch variant and tag it via `register`.
    PATCH_VERSIONS = {}

    # Raised under :strict policy when the runtime Rails/Ruby version isn't in
    # the tested set.
    class UnsupportedVersionError < StandardError; end

    # Strategy modules — one per policy value. Each implements the two
    # messages that previously branched on `case policy`:
    #   mismatch(message)              — version-mismatch handling
    #   missing_ivar(obj, ivar, label, funnel:) — missing-ivar handling
    # The call sites send one message; the branch is gone.
    module Strategy
      module Strict
        def self.mismatch(message)
          raise UnsupportedVersionError, message
        end

        def self.missing_ivar(obj, ivar, label, funnel:)
          raise UnsupportedVersionError,
                "#{label}: missing ivar #{ivar} on #{obj.class}"
        end
      end

      module Off
        def self.mismatch(message)
          # silent
          nil
        end

        def self.missing_ivar(obj, ivar, label, funnel:)
          nil
        end
      end

      module Warn
        def self.mismatch(message)
          warn message
        end

        def self.missing_ivar(obj, ivar, label, funnel:)
          funnel.call(label) { warn "[ractor_rails_shim] #{label}: missing ivar #{ivar} on #{obj.class}" } if RactorRailsShim.debug?
          nil
        end
      end

      MAP = { strict: Strict, off: Off, warn: Warn }.freeze
    end

    class << self
      # Policy for version mismatches. One of :warn (default), :strict, :off.
      # Set before `install`:
      #   RactorRailsShim::VersionPolicy.policy = :strict
      # Defaults to :warn when never explicitly set.
      def policy
        @policy || :warn
      end

      attr_writer :policy

      # Resolve the strategy module for the current policy. The two call
      # sites (VersionPolicy.mismatch, CallbackCapture.read_ivar_or_warn)
      # send a message to this instead of branching on `case policy`.
      def strategy
        Strategy::MAP[policy] || Strategy::Warn
      end

      # Apply the configured policy to a mismatch message. Delegates to the
      # strategy module — no `case` branch.
      def mismatch(message)
        strategy.mismatch(message)
      end

      # Record that a patch was developed/tested against the given Rails
      # version segments. Idempotent and dedupes segments. Called by each
      # install_* method.
      def register(name, *tested_segments)
        existing = PATCH_VERSIONS[name] || []
        PATCH_VERSIONS[name] = (existing + tested_segments).uniq
      end

      # Report which registered patches apply to the runtime Rails version
      # (and which were skipped because they're untested on it). Returns a
      # Hash: { applied: [...], skipped: [...] }.
      def applicable
        seg = RactorRailsShim::Version.rails_segment
        applied = []
        skipped = []
        PATCH_VERSIONS.each do |name, tested|
          if seg.nil? || tested.include?(seg)
            applied << name
          else
            skipped << { name: name, tested: tested, runtime: seg }
          end
        end
        { applied: applied, skipped: skipped }
      end
    end
  end
end