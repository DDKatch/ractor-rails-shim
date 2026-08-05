# frozen_string_literal: true

# VersionPolicy: the policy switch + patch-version registry.
#
# Version *detection* (reading runtime Ruby/Rails versions, segment
# extraction, satisfies?) lives in RactorRailsShim::Version. This module owns
# the orthogonal concern: what to *do* on a mismatch (the :warn/:strict/:off
# policy) and the registry mapping each install_* patch name to the Rails
# versions it was tested against. Extracted from the RactorRailsShim singleton
# (core.rb) so the policy is independently specable.
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

    class << self
      # Policy for version mismatches. One of :warn (default), :strict, :off.
      # Set before `install`:
      #   RactorRailsShim::VersionPolicy.policy = :strict
      # Defaults to :warn when never explicitly set.
      def policy
        @policy || :warn
      end

      attr_writer :policy

      # Apply the configured policy to a mismatch message.
      def mismatch(message)
        case policy
        when :strict
          raise UnsupportedVersionError, message
        when :off
          # silent
        else
          warn message
        end
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