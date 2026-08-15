# frozen_string_literal: true

module RactorRailsShim
  # Marcel ships a handful of class/singleton methods that are implemented with
  # blocks (`each { }`, `map { }`, `reduce { }`, `&block`, etc.). Those blocks
  # are compiled in the main Ractor, so any worker Ractor that calls into Marcel
  # (ActiveStorage uses it for content-type detection when attaching files) blows
  # up with "defined with an un-shareable Proc in a different Ractor".
  #
  # We also freeze Marcel's global lookup tables (EXTENSIONS / MAGIC / TYPE_EXTS /
  # TYPE_PARENTS) so they are Ractor-shareable.
  #
  # Both fixes are applied by re-defining the methods with string-eval `def`s that
  # contain no blocks, and by making every Marcel constant shareable.
  module MarcelPatch
    module_function

    def apply!
      make_constants_shareable!
      patch_mime_type!
      patch_magic!
    end

    # Freeze every top-level Marcel constant (and the nested arrays/hashes) so the
    # lookup tables can be transferred into worker Ractors.
    def make_constants_shareable!
      return unless defined?(::Marcel)

      ::Marcel.constants(false).each do |name|
        obj = ::Marcel.const_get(name)
        Ractor.make_shareable(obj) if Ractor.respond_to?(:make_shareable) && !Ractor.shareable?(obj)
        ::Marcel.const_set(name, obj)
      rescue
        nil
      end
    end

    # Override MimeType.for_data / with_io / most_specific_type without blocks.
    def patch_mime_type!
      return unless defined?(::Marcel::MimeType)

      ::Marcel::MimeType.singleton_class.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        def for_data(pathname_or_io)
          if pathname_or_io
            io = with_io(pathname_or_io)
            begin
              if magic = ::Marcel::Magic.by_magic(io)
                magic.type.downcase
              end
            ensure
              io.close if defined?(::Pathname) && pathname_or_io.is_a?(::Pathname)
            end
          end
        end

        def with_io(pathname_or_io)
          if defined?(::Pathname) && pathname_or_io.is_a?(::Pathname)
            pathname_or_io.open
          else
            pathname_or_io
          end
        end

        def most_specific_type(*candidates)
          arr = candidates.compact.uniq
          return nil if arr.empty?
          type = arr[0]
          i = 1
          while i < arr.length
            candidate = arr[i]
            type = ::Marcel::Magic.child?(candidate, type) ? candidate : type
            i += 1
          end
          type
        end
      RUBY
    end

    # Override Magic.add / remove / all_by_magic / child? / magic_match without blocks.
    def patch_magic!
      return unless defined?(::Marcel::Magic)

      ::Marcel::Magic.singleton_class.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        def add(type, options)
          extensions = [options[:extensions]].flatten.compact
          ::Marcel::TYPE_EXTS[type] = extensions
          parents = [options[:parents]].flatten.compact
          ::Marcel::TYPE_PARENTS[type] = parents unless parents.empty?
          i = 0
          while i < extensions.length
            ::Marcel::EXTENSIONS[extensions[i]] = type
            i += 1
          end
          ::Marcel::MAGIC.unshift [type, options[:magic]] if options[:magic]
        end

        def remove(type)
          ext_keys = ::Marcel::EXTENSIONS.keys
          i = 0
          while i < ext_keys.length
            k = ext_keys[i]
            ::Marcel::EXTENSIONS.delete(k) if ::Marcel::EXTENSIONS[k] == type
            i += 1
          end
          j = 0
          while j < ::Marcel::MAGIC.length
            if ::Marcel::MAGIC[j][0] == type
              ::Marcel::MAGIC.delete_at(j)
            else
              j += 1
            end
          end
          ::Marcel::TYPE_EXTS.delete(type)
          ::Marcel::TYPE_PARENTS.delete(type)
        end

        def all_by_magic(io)
          matches = magic_match(io, :select)
          result = []
          i = 0
          while i < matches.length
            result << new(matches[i][0])
            i += 1
          end
          result
        end

        def child?(child, parent)
          return true if child == parent
          parents = ::Marcel::TYPE_PARENTS[child]
          return false unless parents
          i = 0
          while i < parents.length
            return true if child?(parents[i], parent)
            i += 1
          end
          false
        end

        def magic_match(io, method)
          return magic_match(::StringIO.new(io.to_s), method) unless io.respond_to?(:read)
          buffer = "".b
          if method == :find
            i = 0
            while i < ::Marcel::MAGIC.length
              entry = ::Marcel::MAGIC[i]
              return [entry[0], entry[1]] if magic_match_io(io, entry[1], buffer)
              i += 1
            end
            nil
          else
            result = []
            i = 0
            while i < ::Marcel::MAGIC.length
              entry = ::Marcel::MAGIC[i]
              result << [entry[0], entry[1]] if magic_match_io(io, entry[1], buffer)
              i += 1
            end
            result
          end
        end

        def magic_match_io(io, matches, buffer)
          i = 0
          while i < matches.length
            offset, value, children = matches[i]
            match = nil
            if value
              if value.is_a?(::Regexp)
                match = match_regex(io, offset, value, buffer)
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
            return true if match && (!children || magic_match_io(io, children, buffer))
            i += 1
          end
          false
        end
      RUBY
    end
  end

  def self._install_marcel_patch = MarcelPatch.apply!
end
