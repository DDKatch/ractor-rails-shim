# frozen_string_literal: true

# Version detection and gating for ractor-rails-shim.
#
# The shim's patches target specific Rails class layouts (class_attribute,
# Callbacks, PathRegistry, LookupContext, …) and Ruby Ractor semantics that
# change between releases. Applying an 8.1-targeted patch to a 7.1 app would
# silently miss blockers or redefine the wrong methods. This module makes the
# version checks robust (Gem::Version, not string prefix comparison) and gives
# each patch a tested-versions tag so the dispatcher can apply only patches
# that match the runtime.
#
# Three concerns live here:
#
#  1. Reading the runtime versions (Ruby + Rails) defensively — Rails may not
#     be loaded yet at install time.
#  2. A policy switch for mismatches: :warn (default, backward compatible),
#     :strict (raise), or :off (silent). Set via
#     `RactorRailsShim.version_policy = :strict`.
#  3. A registry (`PATCH_VERSIONS`) mapping each install_* patch name to the
#     Rails versions it was developed and tested against, plus reporters
#     (`applicable_patches` / `skipped_patches`) so users (and CI) can see
#     exactly what applied to their runtime.
module RactorRailsShim
  module Version
    # Ruby version the shim was developed against (major.minor.patch). Ractor
    # semantics are still settling; the frozen-iseq call-cache fix (#22075) and
    # the cross-ractor env-string fix that the shim relies on both shipped in
    # 4.0.6, so earlier 4.0.x patch releases are NOT supported.
    SUPPORTED_RUBY = "4.0.6"
    # Rails versions each patch was tested against. Patches are registered
    # with one or more entries from this list; the dispatcher applies a patch
    # only if the runtime Rails version matches one of its tags. To add 7.x
    # support, write the version-specific patch variants and add the tag here.
    TESTED_RAILS = ["8.1"].freeze

    class << self
      # Runtime Ruby version as a Gem::Version (e.g. "4.0.6"). Always
      # available — Ruby is obviously loaded.
      def ruby
        Gem::Version.new(RUBY_VERSION)
      end

      # Runtime Rails version as a Gem::Version, or nil if Rails isn't
      # loaded yet (the normal config/boot.rb case — install is called before
      # `require "rails"`).
      def rails
        return nil unless defined?(::Rails) && defined?(::Rails::VERSION)
        return nil if ::Rails::VERSION::STRING.nil? || ::Rails::VERSION::STRING.empty?
        begin
          Gem::Version.new(::Rails::VERSION::STRING)
        rescue ArgumentError
          nil
        end
      end

      # Major.minor segment as a String ("8.1"), or nil if Rails isn't loaded.
      def rails_segment
        return nil unless (rv = rails)
        "#{rv.segments[0]}.#{rv.segments[1]}"
      end

      # Major.minor segment of the running Ruby.
      def ruby_segment
        v = ruby
        "#{v.segments[0]}.#{v.segments[1]}"
      end

      # True if the runtime Ruby is >= the supported version (4.0.6). Uses a
      # full Gem::Version compare (not a segment match) so the minimum patch
      # release is enforced — the shim relies on fixes that shipped in 4.0.6.
      def supported_ruby?
        ruby >= Gem::Version.new(SUPPORTED_RUBY)
      end

      # True if the runtime Rails major.minor is in the tested set (or Rails
      # isn't loaded yet — can't decide, so optimistic).
      def supported_rails?
        return true unless rails # Rails not loaded: defer decision.
        TESTED_RAILS.include?(rails_segment)
      end

      # Compare a runtime segment ("8.1") against a Gem::Requirement string
      # (e.g. ">= 7.0", "~> 8.1"). Returns true if the segment satisfies the
      # requirement. Used by the patch registry to decide applicability.
      def satisfies?(segment, requirement)
        return false if segment.nil?
        Gem::Requirement.new(requirement).satisfied_by?(Gem::Version.new(segment))
      end
    end
  end
end
