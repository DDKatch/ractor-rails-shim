# frozen_string_literal: true

module RactorRailsShim
  # Marcel ships class/singleton methods that are implemented with blocks
  # (`each { }`, `map { }`, `delete_if { }`, `any? { }`, `reduce { }`). Those
  # blocks are compiled in the main Ractor, so any worker Ractor that calls
  # into Marcel (ActiveStorage uses it for content-type detection when
  # attaching files) blows up with "defined with an un-shareable Proc in a
  # different Ractor".
  #
  # Main-verbatim fix (same philosophy as the i18n patch):
  #
  # * The main Ractor runs upstream marcel 1.2.1 code verbatim. Its global
  #   lookup tables (EXTENSIONS / MAGIC / TYPE_EXTS / TYPE_PARENTS) stay
  #   mutable — the public `Magic.add` / `Magic.remove` API mutates them, and
  #   freezing them broke `test_add_and_remove_type` (FrozenError) and any
  #   app that registers a custom MIME type after boot.
  # * Worker Ractors route through block-free re-implementations that read a
  #   FROZEN SNAPSHOT of those tables (`MarcelPatch::SNAPSHOT`, deep-copied
  #   and made shareable). The upstream tables are never read from a worker,
  #   so their un-shareability does not matter there.
  # * `Magic.add` / `Magic.remove` are the only upstream mutation points.
  #   The routed wrappers call the upstream original in the main Ractor and
  #   then refresh the snapshot, so a custom type registered after dispatch
  #   is visible to workers too. (The tables also mutate at require time via
  #   `definitions.rb` — that runs before dispatch, so the snapshot built at
  #   dispatch already includes it.)
  # * `Magic.add` / `Magic.remove` from a worker raise a descriptive error:
  #   registering a MIME type inside a worker cannot be reflected in the
  #   frozen snapshot, and the old freeze-everything behavior raised a bare
  #   FrozenError there anyway.
  module MarcelPatch
    module_function

    def apply!
      # The require hook can fire MID-require (the `Marcel` module exists as
      # soon as marcel/version.rb loads, but tables.rb / magic.rb /
      # mime_type.rb may not have run yet). Every step guards its own
      # prerequisites; dispatch re-runs apply! after the gem is fully loaded,
      # which completes any step that was skipped here.
      return unless tables_ready?
      build_snapshot!
      # re-applied after the first install: never re-alias an already-routed
      # method (that would chain __shim_upstream_* to itself → recursion)
      if defined?(::Marcel::Magic) && !::Marcel::Magic.respond_to?(:__shim_upstream_add, true)
        patch_magic!
      end
      if defined?(::Marcel::MimeType) && !::Marcel::MimeType.respond_to?(:__shim_upstream_for_data, true)
        patch_mime_type!
      end
    end

    # All four lookup tables are defined (tables.rb has fully loaded).
    def tables_ready?
      return false unless defined?(::Marcel)
      %i[EXTENSIONS MAGIC TYPE_EXTS TYPE_PARENTS].all? { |c| ::Marcel.const_defined?(c, false) }
    end

    # -- snapshot ----------------------------------------------------------------

    # Deep-copied, deep-frozen view of Marcel's four global lookup tables.
    # Read ONLY from worker Ractors (and from the worker re-implementations
    # below); the main Ractor keeps using the live upstream tables.
    def build_snapshot!
      return unless defined?(::Ractor) && ::Ractor.respond_to?(:make_shareable)

      snap = {
        extensions:   frozen_copy(::Marcel::EXTENSIONS),
        magic:        frozen_copy(::Marcel::MAGIC),
        type_exts:    frozen_copy(::Marcel::TYPE_EXTS),
        type_parents: frozen_copy(::Marcel::TYPE_PARENTS),
      }
      remove_const(:SNAPSHOT) if const_defined?(:SNAPSHOT, false)
      const_set(:SNAPSHOT, snap.freeze)
    end

    # Marshal round-trip first: the copy must be independent of the upstream
    # tables (freezing shared nested arrays would leak into the live tables).
    def frozen_copy(table)
      ::Ractor.make_shareable(::Marshal.load(::Marshal.dump(table)))
    end

    # True only in a non-main Ractor. On Rubies without Ractor (or JRuby's
    # stub) every route below takes the upstream path.
    def worker?
      return false unless defined?(::Ractor) && ::Ractor.respond_to?(:main?)
      !::Ractor.main?
    end

    def snap
      SNAPSHOT
    end

    # -- worker re-implementations (block-free, SNAPSHOT-only) --------------------

    def worker_by_extension(ext)
      ext = ext.to_s.downcase
      mime = ext[0..0] == "." ? snap[:extensions][ext[1..]] : snap[:extensions][ext]
      mime && ::Marcel::Magic.new(mime)
    end

    def worker_extensions_for(type)
      snap[:type_exts][type] || []
    end

    def worker_all_by_magic(io)
      matches = worker_magic_match(io, :select)
      result = []
      i = 0
      while i < matches.length
        result << ::Marcel::Magic.new(matches[i][0])
        i += 1
      end
      result
    end

    def worker_child?(child, parent)
      return true if child == parent
      parents = snap[:type_parents][child]
      return false unless parents
      i = 0
      while i < parents.length
        return true if worker_child?(parents[i], parent)
        i += 1
      end
      false
    end

    def worker_most_specific_type(*candidates)
      arr = candidates.compact.uniq
      return nil if arr.empty?
      type = arr[0]
      i = 1
      while i < arr.length
        candidate = arr[i]
        type = worker_child?(candidate, type) ? candidate : type
        i += 1
      end
      type
    end

    def worker_for_data(pathname_or_io)
      return nil unless pathname_or_io
      io = pathname_or_io
      io = io.open if defined?(::Pathname) && pathname_or_io.is_a?(::Pathname)
      begin
        if magic = ::Marcel::Magic.by_magic(io)
          magic.type.downcase
        end
      ensure
        io.close if defined?(::Pathname) && pathname_or_io.is_a?(::Pathname)
      end
    end

    def worker_magic_match(io, method)
      return worker_magic_match(::StringIO.new(io.to_s), method) unless io.respond_to?(:read)
      buffer = "".b
      entries = snap[:magic]
      if method == :find
        i = 0
        while i < entries.length
          entry = entries[i]
          return [entry[0], entry[1]] if worker_magic_match_io(io, entry[1], buffer)
          i += 1
        end
        nil
      else
        result = []
        i = 0
        while i < entries.length
          entry = entries[i]
          result << [entry[0], entry[1]] if worker_magic_match_io(io, entry[1], buffer)
          i += 1
        end
        result
      end
    end

    def worker_magic_match_io(io, matches, buffer)
      i = 0
      while i < matches.length
        offset, value, children = matches[i]
        match = nil
        if value
          if value.is_a?(::Regexp)
            match = ::Marcel::Magic.send(:match_regex, io, offset, value, buffer)
          elsif ::Range === offset
            io.read(offset.begin, buffer)
            x = io.read(offset.end - offset.begin + value.bytesize, buffer)
            match = x && x.include?(value)
          else
            io.read(offset, buffer)
            match = io.read(value.bytesize, buffer) == value
          end
        end
        io.rewind
        return true if match && (!children || worker_magic_match_io(io, children, buffer))
        i += 1
      end
      false
    end

    # -- patch installation ---------------------------------------------------------

    # Route Magic's singleton methods: upstream verbatim in the main Ractor,
    # snapshot re-implementations in workers. magic_match/magic_match_io stay
    # private like upstream. match_regex has no blocks and no table reads, so
    # it is left untouched.
    def patch_magic!
      return unless defined?(::Marcel::Magic)

      ::Marcel::Magic.singleton_class.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        alias_method :__shim_upstream_add, :add
        def add(type, options)
          if ::RactorRailsShim::MarcelPatch.worker?
            raise ::RuntimeError,
                  "Marcel::Magic.add is main-Ractor only (worker lookup tables are a frozen snapshot); " \\
                  "register custom MIME types before workers boot"
          end
          result = __shim_upstream_add(type, options)
          ::RactorRailsShim::MarcelPatch.build_snapshot!
          result
        end

        alias_method :__shim_upstream_remove, :remove
        def remove(type)
          if ::RactorRailsShim::MarcelPatch.worker?
            raise ::RuntimeError,
                  "Marcel::Magic.remove is main-Ractor only (worker lookup tables are a frozen snapshot); " \\
                  "remove custom MIME types before workers boot"
          end
          result = __shim_upstream_remove(type)
          ::RactorRailsShim::MarcelPatch.build_snapshot!
          result
        end

        alias_method :__shim_upstream_by_extension, :by_extension
        def by_extension(ext)
          return ::RactorRailsShim::MarcelPatch.worker_by_extension(ext) if ::RactorRailsShim::MarcelPatch.worker?
          __shim_upstream_by_extension(ext)
        end

        alias_method :__shim_upstream_all_by_magic, :all_by_magic
        def all_by_magic(io)
          return ::RactorRailsShim::MarcelPatch.worker_all_by_magic(io) if ::RactorRailsShim::MarcelPatch.worker?
          __shim_upstream_all_by_magic(io)
        end

        alias_method :__shim_upstream_child?, :child?
        def child?(child, parent)
          return ::RactorRailsShim::MarcelPatch.worker_child?(child, parent) if ::RactorRailsShim::MarcelPatch.worker?
          __shim_upstream_child?(child, parent)
        end

        alias_method :__shim_upstream_magic_match, :magic_match
        def magic_match(io, method)
          return ::RactorRailsShim::MarcelPatch.worker_magic_match(io, method) if ::RactorRailsShim::MarcelPatch.worker?
          __shim_upstream_magic_match(io, method)
        end

        alias_method :__shim_upstream_magic_match_io, :magic_match_io
        def magic_match_io(io, matches, buffer)
          return ::RactorRailsShim::MarcelPatch.worker_magic_match_io(io, matches, buffer) if ::RactorRailsShim::MarcelPatch.worker?
          __shim_upstream_magic_match_io(io, matches, buffer)
        end
      RUBY

      # by_magic / by_path are untouched upstream methods: by_magic calls the
      # routed magic_match, by_path calls the routed by_extension, and neither
      # dereferences an unshareable constant on its own.

      ::Marcel::Magic.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        alias_method :__shim_upstream_extensions, :extensions
        def extensions
          return ::RactorRailsShim::MarcelPatch.worker_extensions_for(type) if ::RactorRailsShim::MarcelPatch.worker?
          __shim_upstream_extensions
        end
      RUBY

      # restore upstream visibility of the private helpers we redefined
      ::Marcel::Magic.send(:private_class_method, :magic_match, :magic_match_io)
    end

    # MimeType.for / for_name / for_extension / extend are untouched upstream:
    # they call routed Magic methods and never dereference a table constant
    # on a worker path that matters (extend mutating tables from a worker is
    # rejected by the routed Magic.add, as documented above).
    def patch_mime_type!
      return unless defined?(::Marcel::MimeType)

      ::Marcel::MimeType.singleton_class.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        alias_method :__shim_upstream_for_data, :for_data
        def for_data(pathname_or_io)
          return ::RactorRailsShim::MarcelPatch.worker_for_data(pathname_or_io) if ::RactorRailsShim::MarcelPatch.worker?
          __shim_upstream_for_data(pathname_or_io)
        end

        alias_method :__shim_upstream_most_specific_type, :most_specific_type
        def most_specific_type(*candidates)
          return ::RactorRailsShim::MarcelPatch.worker_most_specific_type(*candidates) if ::RactorRailsShim::MarcelPatch.worker?
          __shim_upstream_most_specific_type(*candidates)
        end
      RUBY

      # upstream defines these as private; keep the same visibility
      ::Marcel::MimeType.send(:private_class_method, :for_data, :most_specific_type)
    end
  end

  def self._install_marcel_patch = MarcelPatch.apply!
end
