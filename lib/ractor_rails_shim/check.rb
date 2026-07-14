# frozen_string_literal: true

require_relative "version"

module RactorRailsShim
    # Audit an app for Ractor blockers. Inspects loaded classes/modules for
    # class-level instance variables and mattr_accessor usage that would
    # raise Ractor::IsolationError from a non-main Ractor.
    #
    # Modeled on Kino's `kino --check` — tell the user *exactly* what blocks
    # their app, instead of leaving them to decode IsolationError at runtime.
    class Check
      # kind: :ivar (class-level instance variable, @foo) or
      #      :cvar (class variable, @@foo — mattr_accessor/cattr_accessor)
      Finding = Data.define(:owner, :ivar, :value_class, :shareable, :source, :kind)

      class << self
        # Safely derive a value's class name. BasicObject (and its subclasses)
        # don't define `.class`, so calling it raises NoMethodError — fall back
        # to "BasicObject" in that case.
        def safe_class(val)
          val.class.name || val.class.to_s
        rescue NoMethodError
          "BasicObject"
        end
        private :safe_class

        # Scan all loaded classes/modules and report class ivars AND class
        # variables holding unshareable values. Returns an array of Finding.
        def scan
          findings = []
          seen = {}

          ObjectSpace.each_object(Module) do |mod|
            next if mod.name.nil? || mod.name.empty?
            next if mod.name.start_with?("#", "Ractor::", "Thread::", "Fiber::", "ObjectSpace::")

            # Inspect class-level instance variables.
            mod.instance_variables.each do |ivar|
              next if ivar == :@_sandbox # Rails internal, ignored
              begin
                val = mod.instance_variable_get(ivar)
              rescue => e
                next
              end

              shareable = begin
                Ractor.shareable?(val)
              rescue => e
                false
              end
              next if shareable

              key = "#{mod.name}#{ivar}"
              next if seen[key]
              seen[key] = true

              source = locate(mod, ivar)
              findings << Finding.new(
                owner: mod.name,
                ivar: ivar.to_s,
                value_class: safe_class(val),
                shareable: shareable,
                source: source,
                kind: :ivar
              )
            end

            # Inspect class variables (@@foo) — these back mattr_accessor /
            # cattr_accessor and are ALSO subject to Ractor::IsolationError
            # from non-main Ractors (verified on Ruby 4.0.5).
            begin
              mod.class_variables.each do |cvar|
                begin
                  val = mod.class_variable_get(cvar)
                rescue => e
                  next
                end

                shareable = begin
                  Ractor.shareable?(val)
                rescue => e
                  false
                end
                next if shareable

                key = "#{mod.name}#{cvar}"
                next if seen[key]
                seen[key] = true

                source = locate(mod, cvar)
                findings << Finding.new(
                  owner: mod.name,
                  ivar: cvar.to_s,
                  value_class: safe_class(val),
                  shareable: shareable,
                  source: source,
                  kind: :cvar
                )
              end
            rescue => e
              # Some modules raise on class_variables enumeration; skip.
              next
            end
          end

          findings.sort_by { |f| [f.owner, f.ivar] }
        end

        # Scan only Rails framework modules (Railties, ActiveRecord, etc.)
        # — the ones the shim targets. Useful for "is Rails itself clean?"
        def scan_rails
          scan.select { |f| f.owner.start_with?("Rails", "ActiveRecord", "ActiveSupport",
            "ActionController", "ActionView", "ActionDispatch", "ActionMailer",
            "ActiveJob", "ActionCable", "ActionText", "ActionMailbox", "ActiveStorage") }
        end

        # Scan app + gem classes outside the Rails framework.
        def scan_app
          scan - scan_rails
        end

        # Human-readable report. Returns a string; also prints to $stderr
        # if `print:` is true (default).
        def report(print: true)
          findings = scan
          rails_findings = findings.select { |f| rails_namespace?(f.owner) }
          app_findings = findings - rails_findings

          lines = []
          cvar_count = findings.count { |f| f.kind == :cvar }
          ivar_count = findings.count { |f| f.kind == :ivar }
          lines << "ractor-rails-shim check: #{findings.size} blocker(s) found" \
            " (#{ivar_count} class-ivar, #{cvar_count} class-var)"
          lines << "  (unshareable values in @ivar and @@cvar; reads/writes from a non-main Ractor"
          lines << "   would raise Ractor::IsolationError)"
          lines << ""

          %i[rails app].each do |group|
            grp = group == :rails ? rails_findings : app_findings
            next if grp.empty?

            label = group == :rails ? "Rails framework" : "app + gems"
            lines << "=== #{label} (#{grp.size}) ==="
            grp.first(50).each do |f|
              tag = f.kind == :cvar ? " (mattr/cattr — shim targets)" : ""
              lines << "  #{f.owner}#{f.ivar} = #{f.value_class}#{tag}"
              lines << "    #{f.source}" if f.source
            end
            if grp.size > 50
              lines << "  ... and #{grp.size - 50} more (use Check.scan to see all)"
            end
            lines << ""
          end

          if findings.empty?
            lines << "no blockers found — app may be Ractor-compatible"
          else
            lines << "hints:"
            lines << "  - require \"ractor_rails_shim\" and call RactorRailsShim.install before"
            lines << "    Rails.application is first accessed (early in config/boot.rb)"
            lines << "  - class-var (@@foo) blockers from mattr_accessor/cattr_accessor are"
            lines << "    rerouted by the shim automatically once installed"
            lines << "  - raw class-ivar (@foo) blockers are NOT fixed by the shim; patch the"
            lines << "    gem or use Ractor.make_shareable + a constant for shareable state"
            lines << "  - for per-Ractor mutable state use Ractor.store_if_absent(key) { default }"
          end

          out = lines.join("\n")
          $stderr.puts(out) if print
          out
        end

        private

        def rails_namespace?(name)
          name.start_with?("Rails", "ActiveRecord", "ActiveSupport", "ActionController",
            "ActionView", "ActionDispatch", "ActionMailer", "ActiveJob", "ActionCable",
            "ActionText", "ActionMailbox", "ActiveStorage")
        end

        # Best-effort: locate where the ivar is set in source. Not always
        # possible (set via mattr_accessor macro), but useful when it is.
        def locate(mod, ivar)
          # Check if it's a method-defined accessor (mattr_accessor etc.)
          reader = ivar.to_s.delete("@").to_sym
          if mod.singleton_class.method_defined?(reader)
            m = mod.singleton_class.instance_method(reader)
            if m.source_location
              file, line = m.source_location
              return "#{file}:#{line}"
            end
          end
          nil
        rescue => e
          nil
        end
      end
    end
  end