# frozen_string_literal: true

module RactorRailsShim
  # The stdlib `unicode_normalize/normalize.rb` (backing `String#unicode_normalize`,
  # used by Addressable URI normalization and anything else normalizing user
  # input) compiles its three matching regexps with `Regexp.compile` at load
  # time:
  #
  #     REGEXP_D = Regexp.compile(REGEXP_D_STRING, Regexp::EXTENDED)
  #     REGEXP_C = Regexp.compile(REGEXP_C_STRING, Regexp::EXTENDED)
  #     REGEXP_K = Regexp.compile(REGEXP_K_STRING, Regexp::EXTENDED)
  #
  # Only Regexp LITERALS are frozen by the compiler; `Regexp.compile` returns
  # an unfrozen Regexp, so all three constants hold non-shareable objects and
  # a worker Ractor touching `String#unicode_normalize` dies with
  #   Ractor::IsolationError: can not access non-shareable objects in constant
  #   UnicodeNormalize::REGEXP_C by non-main ractor.
  #
  # Freezing fixes the regexps, but `normalize` / `normalized?` also reach the
  # NF_HASH_C / NF_HASH_D memoization Hashes — Hash objects wired with default
  # procs that the stdlib MUTATES at call time (`hash[key] = nfc_one(key)`,
  # with an anti-DoS `hash.shift`). Freezing them would break main-Ractor
  # memoization itself, so instead `normalize` / `normalized?` get a worker
  # branch that skips the NF-hashes entirely:
  #
  #   * `KOMPATIBLE_TABLE`, `DECOMPOSITION_TABLE`, `COMPOSITION_TABLE`,
  #     `CLASS_TABLE` are frozen upstream already and stay readable
  #     (shareable constants) in workers.
  #   * Workers replace `gsub REGEXP_C, NF_HASH_C` with a block-based gsub
  #     feeding a per-Ractor memo Hash held in the shim's per-Ractor storage
  #     (same lazy work, Ractor-local mutation; the upstream
  #     `MAX_HASH_LENGTH` anti-DoS cap is preserved).
  #   * `UNICODE_ENCODINGS` (an Array of Encoding objects — all shareable) is
  #     frozen in place so the `when *UNICODE_ENCODINGS` re-encode branch
  #     stays worker-readable.
  module UnicodeNormalizePatch
    module_function

    def apply!
      require "unicode_normalize/normalize"
      return if @patched
      @patched = true
      RactorRailsShim.__send__(:_register_patch, :unicode_normalize, "8.1")
      return unless ::Ractor.main? && defined?(::UnicodeNormalize)

      freeze_constants!
      patch_normalize!
      patch_normalized?
    rescue ::LoadError
      nil
    end

    # A frozen Regexp / Array-of-Encodings is shareable. The value-table
    # Hashes upstream ships already frozen are left untouched.
    def freeze_constants!
      %i[REGEXP_D REGEXP_C REGEXP_K UNICODE_ENCODINGS].each do |name|
        value = ::UnicodeNormalize.const_get(name)
        ::Ractor.make_shareable(value) unless ::Ractor.shareable?(value)
      end
    end

    # Main keeps the upstream body verbatim (memoizing NF-hashes included).
    # The worker branch swaps every NF-hash gsub for a block-based gsub
    # (bodies differ ONLY in the replacement argument). `nfc_one` / `nfd_one`
    # are public class methods, so workers recompute per match — memoized
    # per-Ractor through the shim storage to keep the same lazily-warm
    # behavior without touching main's mutable hashes.
    def patch_normalize!
      ::UnicodeNormalize.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def normalize(string, form = :nfc)
          encoding = string.encoding
          case encoding
          when ::Encoding::UTF_8
            case form
            when :nfc then nf_gsub!(string, :c)
            when :nfd then nf_gsub!(string, :d)
            when :nfkc then nf_gsub!(string, :c, compatibility: true)
            when :nfkd then nf_gsub!(string, :d, compatibility: true)
            else
              raise ::ArgumentError, "Invalid normalization form \#{form}."
            end
          when ::Encoding::US_ASCII
            string
          when *::UnicodeNormalize::UNICODE_ENCODINGS
            normalize(string.encode(::Encoding::UTF_8), form).encode(encoding)
          else
            raise ::Encoding::CompatibilityError, "Unicode Normalization not appropriate for \#{encoding}"
          end
        end

        def nf_gsub!(string, kind, compatibility: false)
          if ::Ractor.main?
            string = string.gsub(::UnicodeNormalize::REGEXP_K, ::UnicodeNormalize::KOMPATIBLE_TABLE) if compatibility
            string.gsub(kind == :c ? ::UnicodeNormalize::REGEXP_C : ::UnicodeNormalize::REGEXP_D,
                        kind == :c ? ::UnicodeNormalize::NF_HASH_C : ::UnicodeNormalize::NF_HASH_D)
          else
            string = string.gsub(::UnicodeNormalize::REGEXP_K, ::UnicodeNormalize::KOMPATIBLE_TABLE) if compatibility
            regexp = kind == :c ? ::UnicodeNormalize::REGEXP_C : ::UnicodeNormalize::REGEXP_D
            memo = nf_memo(kind)
            string.gsub(regexp) do |match|
              memo.shift if memo.length > ::UnicodeNormalize::MAX_HASH_LENGTH
              memo[match] ||= kind == :c ? ::UnicodeNormalize.nfc_one(match) : ::UnicodeNormalize.nfd_one(match)
            end
          end
        end

        def nf_memo(kind)
          key = :"ractor_rails_shim_unicode_nf_\#{kind}"
          ::RactorRailsShim.storage[key] ||= {}
          ::RactorRailsShim.storage[key]
        end
      RUBY
    end

    # Same split: main uses `NF_HASH_C[match]` lookups verbatim, workers
    # recompute `nfc_one` / `nfd_one` per match (comparison only — no memo
    # churn needed for a boolean check).
    def patch_normalized?
      ::UnicodeNormalize.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def normalized?(string, form = :nfc)
          encoding = string.encoding
          case encoding
          when ::Encoding::UTF_8
            case form
            when :nfc
              string.scan(::UnicodeNormalize::REGEXP_C) do |match|
                return false if !::Ractor.main? ?
                  ::UnicodeNormalize.nfc_one(match) != match :
                  ::UnicodeNormalize::NF_HASH_C[match] != match
              end
              true
            when :nfd
              string.scan(::UnicodeNormalize::REGEXP_D) do |match|
                return false if !::Ractor.main? ?
                  ::UnicodeNormalize.nfd_one(match) != match :
                  ::UnicodeNormalize::NF_HASH_D[match] != match
              end
              true
            when :nfkc then normalized?(string, :nfc) and string !~ ::UnicodeNormalize::REGEXP_K
            when :nfkd then normalized?(string, :nfd) and string !~ ::UnicodeNormalize::REGEXP_K
            else
              raise ::ArgumentError, "Invalid normalization form \#{form}."
            end
          when ::Encoding::US_ASCII
            true
          when *::UnicodeNormalize::UNICODE_ENCODINGS
            normalized?(string.encode(::Encoding::UTF_8), form).dup
          else
            raise ::Encoding::CompatibilityError, "Unicode Normalization not appropriate for \#{encoding}"
          end
        end
      RUBY
    end
  end

  def self._install_unicode_normalize_patch = UnicodeNormalizePatch.apply!
end
