# frozen_string_literal: true

# ActiveStorage `has_one_attached` / `has_many_attached` register a
# `has_one`/`has_many` association whose SCOPE is an inline lambda
# `-> { where(name: name) }`. That lambda's defining `self` is the
# ActiveRecord association BUILDER instance (e.g.
# `ActiveRecord::Associations::Builder::HasOne`) — which is NOT
# Ractor-shareable. As a result `Ractor.make_shareable(User.reflections)`
# fails (the scope Proc can't be shared), so worker Ractors fall back to an
# EMPTY reflections hash and raise `AssociationNotFoundError: Association
# named 'avatar_attachment' was not found on User`.
#
# AR invokes association scopes via
# `relation.instance_exec(owner, &scope)` (activerecord/associations/
# association_scope.rb:171), so the scope's defining `self` is irrelevant at
# call time — only its CLOSURE matters. We re-implement the two macros
# (faithful to Rails 8.1.3.1) but define the scope lambda with a SHAREABLE
# defining `self` (a frozen module). The closure (`name`, a Symbol) is
# shareable, so the whole reflections hash becomes Ractor-shareable and the
# worker fallback captures it.
#
# Only the scope-lambda construction changes; every other line matches
# upstream so attachment semantics (attachment_changes, after_save/commit
# callbacks, the attached reflection) are preserved.

module RactorRailsShim
  # Shareable constants holding ActiveStorage's table-name prefix/suffix.
  # Seeded with the real (string) values in main at prepare_for_ractors! time
  # (see `_seed_active_storage_prefix!`); workers read these instead of the
  # un-shareable `mattr_accessor` readers. Reassigned (not mutated) in main.
  ACTIVE_STORAGE_PREFIX = "".freeze
  ACTIVE_STORAGE_SUFFIX = "".freeze

  module ActiveStorageAttachedPatch
    # Frozen, shareable host used as the defining `self` of attachment scope
    # lambdas. A frozen Module is Ractor-shareable, so a lambda created via
    # `SHAREABLE_SCOPE_HOST.instance_eval { -> { where(name: name) } }` has a
    # shareable `self` and makes `Ractor.make_shareable(reflections)` succeed.
    SHAREABLE_SCOPE_HOST = Module.new.freeze

    # `ActiveStorage::Blob#compute_checksum_in_chunks` computes the MD5 via
    # `OpenSSL::Digest::MD5.new.tap do |checksum| ... end` — `tap` takes a
    # block compiled in the main Ractor, which is un-shareable and raises
    # "defined with an un-shareable Proc in a different Ractor" when a worker
    # uploads an attachment. Reimplement without a block (plain `while` loop).
    module BlobChecksumPatch
      def compute_checksum_in_chunks(io)
        raise ArgumentError, "io must be rewindable" unless io.respond_to?(:rewind)

        checksum = OpenSSL::Digest::MD5.new
        read_buffer = "".b
        while io.read(5.megabytes, read_buffer)
          checksum << read_buffer
        end
        io.rewind
        checksum.base64digest
      end
    end

    # `ActiveStorage::Blob.build_after_unfurling` is implemented as
    # `new(...).tap do |blob| blob.unfurl(io, identify: identify) end`. The
    # `tap` block is compiled in the main Ractor and is un-shareable, so a
    # worker that creates a blob raises "defined with an un-shareable Proc in a
    # different Ractor". Reimplement with the same (all-keyword) signature but
    # without a block.
    module BlobBuildPatch
      def build_after_unfurling(key: nil, io:, filename:, content_type: nil, metadata: nil, service_name: nil, identify: true, record: nil)
        blob = new(key: key, filename: filename, content_type: content_type, metadata: metadata, service_name: service_name)
        blob.unfurl(io, identify: identify)
        blob
      end
    end

    # `ActiveStorage::Blob#metadata` is declared via `store :metadata`, which
    # should register a `Type::Serialized` cast type. When `ActiveStorage::Blob`
    # is freshly autoloaded in a worker Ractor's empty constant namespace (before
    # the DB connection/schema is established), `cast_types` is built from an empty
    # `columns_hash`, the `:metadata` decorator is silently skipped, and
    # `type_for_attribute(:metadata)` returns a plain `Type::Text`/`Type::Value`.
    # That makes `store_accessor_for` raise "the column 'metadata' has not been
    # configured as a store". Force a `Type::Serialized` for `:metadata` so
    # worker uploads work regardless of load order.
    #
    # `read_attribute(:metadata)` does NOT go through `type_for_attribute`; it
    # uses the cached `@attributes` set built from `_default_attributes` →
    # `attribute_types` → `cast_types`, which memoizes a plain `Type::Value` if
    # the class was loaded without the serialized decorator. We patch
    # `attribute_types` to return `Type::Serialized` for `:metadata`, but since
    # the frozen shared graph prevents writing class ivars in a worker, the
    # REAL fix is to rebuild `_default_attributes` in MAIN at
    # `prepare_for_ractors!` time (see `_fix_blob_metadata_type!` below), so the
    # frozen graph carries the correct `Type::Serialized` from the start. The
    # `attribute_types` / `type_for_attribute` overrides are fallbacks for the
    # case where the class is freshly autoloaded in a worker (separate process).
    module BlobMetadataTypePatch
      def type_for_attribute(name = :__none__)
        return super if name != :metadata
        t = super(name)
        return t if defined?(::ActiveRecord::Type::Serialized) && t.is_a?(::ActiveRecord::Type::Serialized)
        coder = ::ActiveRecord::Coders::JSON.new
        ind_coder = ::ActiveRecord::Store::IndifferentCoder.new(:metadata, coder)
        ::ActiveRecord::Type::Serialized.new(t, ind_coder)
      end

      def attribute_types
        types = super
        return types if types[:metadata].is_a?(::ActiveRecord::Type::Serialized)
        # Worker-safe: don't try to memoize (can't write class ivars in a
        # non-main Ractor). Return a fresh Hash with the corrected type each
        # call. The overhead is negligible (this path is worker-only).
        corrected = types.dup
        coder = ::ActiveRecord::Coders::JSON.new
        ind_coder = ::ActiveRecord::Store::IndifferentCoder.new(:metadata, coder)
        corrected[:metadata] = ::ActiveRecord::Type::Serialized.new(
          types[:metadata] || ::ActiveModel::Type::Value.new,
          ind_coder
        )
        corrected
      end
    end

    # `ActiveStorage::Blob#service_name` is normally defaulted in an
    # `after_initialize` callback (`self.service_name ||= self.class.service&.name`).
    # The shim's callback replay runs only captured transport filters in a worker
    # Ractor and skips model-level `after_initialize`, so `service_name` stays nil
    # in a worker and `ActiveStorage::Blob#service` raises "undefined method
    # 'to_sym' for nil" (it does `services.fetch(service_name)`). Fall back to the
    # class-configured default service name when the attribute is blank, so the
    # service resolves without depending on the skipped callback.
    module ActiveStorageServicePatch
      def service_name
        # Read the raw attribute directly (not via the lazily-generated
        # `service_name` reader, which this prepended method would shadow and
        # break with `super`). Fall back to the class-configured default service
        # name when the attribute is blank.
        value = read_attribute(:service_name)
        value.presence || self.class.service&.name
      end
    end

    def has_one_attached(name, dependent: :purge_later, service: nil, strict_loading: false)
      ActiveStorage::Attached::Model.validate_service_configuration(service, self, name) unless service.is_a?(Proc)

      generated_association_methods.class_eval <<-CODE, __FILE__, __LINE__ + 1
        # frozen_string_literal: true
        def #{name}
          @active_storage_attached ||= {}
          @active_storage_attached[:#{name}] ||= ActiveStorage::Attached::One.new("#{name}", self)
        end

        def #{name}=(attachable)
          attachment_changes["#{name}"] =
            if attachable.nil? || attachable == ""
              ActiveStorage::Attached::Changes::DeleteOne.new("#{name}", self)
            else
              ActiveStorage::Attached::Changes::CreateOne.new("#{name}", self, attachable)
            end
        end
      CODE

      # Ractor fix: scope lambda built with a shareable `self` so the
      # reflection (and therefore `User.reflections`) is Ractor-shareable.
      scope_lambda = SHAREABLE_SCOPE_HOST.instance_eval { ->(record = nil) { where(name: name) } }
      has_one :"#{name}_attachment", scope_lambda, class_name: "ActiveStorage::Attachment", as: :record, inverse_of: :record, dependent: :destroy, strict_loading: strict_loading
      has_one :"#{name}_blob", through: :"#{name}_attachment", class_name: "ActiveStorage::Blob", source: :blob, strict_loading: strict_loading

      scope :"with_attached_#{name}", -> {
        if ActiveStorage.track_variants
          includes("#{name}_attachment": { blob: {
            variant_records: { image_attachment: :blob },
            preview_image_attachment: { blob: { variant_records: { image_attachment: :blob } } }
          } })
        else
          includes("#{name}_attachment": :blob)
        end
      }

      after_save { attachment_changes[name.to_s]&.save }

      after_commit(on: %i[ create update ]) { attachment_changes.delete(name.to_s).try(:upload) }

      reflection = ActiveRecord::Reflection.create(
        :has_one_attached,
        name,
        nil,
        { dependent: dependent, service_name: service },
        self
      )
      yield reflection if block_given?
      ActiveRecord::Reflection.add_attachment_reflection(self, name, reflection)
    end

    def has_many_attached(name, dependent: :purge_later, service: nil, strict_loading: false)
      ActiveStorage::Attached::Model.validate_service_configuration(service, self, name) unless service.is_a?(Proc)

      generated_association_methods.class_eval <<-CODE, __FILE__, __LINE__ + 1
        # frozen_string_literal: true
        def #{name}
          @active_storage_attached ||= {}
          @active_storage_attached[:#{name}] ||= ActiveStorage::Attached::Many.new("#{name}", self)
        end

        def #{name}=(attachables)
          attachables = Array(attachables).compact_blank
          pending_uploads = attachment_changes["#{name}"].try(:pending_uploads)

          attachment_changes["#{name}"] = if attachables.none?
            ActiveStorage::Attached::Changes::DeleteMany.new("#{name}", self)
          else
            ActiveStorage::Attached::Changes::CreateMany.new("#{name}", self, attachables, pending_uploads: pending_uploads)
          end
        end
      CODE

      scope_lambda = SHAREABLE_SCOPE_HOST.instance_eval { ->(record = nil) { where(name: name) } }
      has_many :"#{name}_attachments", scope_lambda, as: :record, class_name: "ActiveStorage::Attachment", inverse_of: :record, dependent: :destroy, strict_loading: strict_loading
      has_many :"#{name}_blobs", through: :"#{name}_attachments", class_name: "ActiveStorage::Blob", source: :blob, strict_loading: strict_loading

      scope :"with_attached_#{name}", -> {
        if ActiveStorage.track_variants
          includes("#{name}_attachments": { blob: {
            variant_records: { image_attachment: :blob },
            preview_image_attachment: { blob: { variant_records: { image_attachment: :blob } } }
          } })
        else
          includes("#{name}_attachments": :blob)
        end
      }

      after_save { attachment_changes[name.to_s]&.save }

      after_commit(on: %i[ create update ]) { attachment_changes.delete(name.to_s).try(:upload) }

      reflection = ActiveRecord::Reflection.create(
        :has_many_attached,
        name,
        nil,
        { dependent: dependent, service_name: service },
        self
      )
      yield reflection if block_given?
      ActiveRecord::Reflection.add_attachment_reflection(self, name, reflection)
    end
  end

  class << self
    def _install_active_storage_patch
      # Freeze the SecureRandom alphabets on every dispatch: they are defined
      # lazily during boot, so the first dispatch (early install) may run before
      # they exist while a later dispatch (prepare_for_ractors!, after boot)
      # finds them defined. `_install_secure_random_alphabets!` is itself
      # idempotent and only acts when needed.
      _install_secure_random_alphabets!
      return if @active_storage_patched
      @active_storage_patched = true
      @_as_patched_macros = false
      @_as_patched_blob = false

      _maybe_apply_active_storage_patch

      unless @_as_patched_macros && @_as_patched_blob
        # ActiveStorage's `:active_storage` load hook does not reliably fire in
        # every boot (e.g. a bare `config/application` + initialize! boot), and
        # the macro module must be patched BEFORE any app model calls
        # `has_one_attached`/`has_many_attached` (during eager-load). Watch for
        # the relevant modules to be opened with a TracePoint(:class); once each
        # constant is defined, prepend. ActiveStorage::Blob loads *after*
        # ActiveStorage::Attached::Model::ClassMethods, so it is patched in a
        # later trace event.
        @_as_tp = TracePoint.new(:class) do |tp|
          _maybe_apply_active_storage_patch
          if @_as_patched_macros && @_as_patched_blob
            @_as_tp.disable
            @_as_tp = nil
          end
        end
        @_as_tp.enable
      end
    end

    # `ActiveSupport` core-ext defines `SecureRandom::BASE36_ALPHABET` /
    # `BASE58_ALPHABET` as Arrays of non-frozen Strings. These constants are
    # read by `SecureRandom.base36` / `base58`, which `ActiveStorage::Blob` calls
    # to generate upload keys. A worker Ractor raises IsolationError accessing a
    # non-shareable constant, so deep-freeze them (making them shareable) in the
    # main Ractor. They are immutable by contract, so freezing is safe.
    #
    # The core-ext is loaded lazily during boot. The constants are defined via
    # module-body assignment (`BASE36_ALPHABET = (...)`), which does NOT fire a
    # TracePoint(:constant) event, so we can't rely on the trace alone. Instead
    # we attempt the freeze at install time AND at prepare_for_ractors! time
    # (after `initialize!`, when the core-ext is guaranteed loaded). The
    # `_freeze_secure_random_alphabets!` helper is idempotent and skips already
    # shareable constants.
    def _install_secure_random_alphabets!
      _freeze_secure_random_alphabets!
      return if @_secure_random_tp
      return unless defined?(::SecureRandom)

      @_secure_random_tp = TracePoint.new(:constant) do |tp|
        name = tp.const_name
        next unless name == "SecureRandom::BASE36_ALPHABET" ||
                    name == "SecureRandom::BASE58_ALPHABET"
        _freeze_secure_random_alphabets!
        if %i[BASE36_ALPHABET BASE58_ALPHABET].all? do |c|
             ::SecureRandom.const_defined?(c) && ::Ractor.shareable?(::SecureRandom.const_get(c))
           end
          @_secure_random_tp.disable
          @_secure_random_tp = nil
        end
      end
      @_secure_random_tp.enable
    rescue StandardError
      nil
    end

    # Freeze `SecureRandom::BASE36_ALPHABET` / `BASE58_ALPHABET` if they exist
    # and are not yet shareable. Idempotent — safe to call from install, from
    # prepare_for_ractors!, and from the TracePoint callback.
    def _freeze_secure_random_alphabets!
      return unless defined?(::SecureRandom)
      %i[BASE36_ALPHABET BASE58_ALPHABET].each do |const|
        next unless ::SecureRandom.const_defined?(const)
        alphabet = ::SecureRandom.const_get(const)
        next if ::Ractor.shareable?(alphabet)
        ::SecureRandom.const_set(const, ::Ractor.make_shareable(alphabet))
      rescue StandardError
        nil
      end
    end

    def _maybe_apply_active_storage_patch
      _apply_active_storage_macro_patch unless @_as_patched_macros
      _apply_active_storage_blob_patch unless @_as_patched_blob
    end

    def _apply_active_storage_macro_patch
      return unless defined?(::ActiveStorage::Attached::Model::ClassMethods)
      ::ActiveStorage::Attached::Model::ClassMethods.prepend(ActiveStorageAttachedPatch)

      # `ActiveStorage.table_name_prefix` / `table_name_suffix` are declared via
      # `mattr_accessor` (railties/engine.rb) whose reader is an un-shareable
      # `define_method` Proc when invoked from a worker Ractor. They feed
      # `ActiveRecord::ModelSchema#full_table_name_prefix`, which
      # `compute_table_name` calls for any ActiveStorage model whose explicit
      # `table_name=` (set in main) is invisible to a worker's per-Ractor IES —
      # so without this fix a worker raises "defined with an un-shareable Proc".
      # Redefine the readers as shareable string-eval `def`s that return the
      # shareable ACTIVE_STORAGE_PREFIX / ACTIVE_STORAGE_SUFFIX constants. Those
      # constants are seeded with the real values in main at prepare_for_ractors!
      # time (see `_seed_active_storage_prefix!`), so workers read the correct
      # prefix ("active_storage_") without crossing the Ractor boundary.
      if defined?(::ActiveStorage)
        ::ActiveStorage.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def table_name_prefix; RactorRailsShim::ACTIVE_STORAGE_PREFIX; end
          def table_name_suffix; RactorRailsShim::ACTIVE_STORAGE_SUFFIX; end
        RUBY
      end

      @_as_patched_macros = true
      _register_patch :active_storage, "8.1"
    end

    # `ActiveStorage::Blob` is loaded *after* the attached macros, so it is
    # patched in a later TracePoint event. Both methods here use un-shareable
    # blocks compiled in the main Ractor, which raise "defined with an
    # un-shareable Proc in a different Ractor" when a worker uploads an
    # attachment; reimplement without blocks.
    def _apply_active_storage_blob_patch
      return unless defined?(::ActiveStorage::Blob)
      ::ActiveStorage::Blob.prepend(ActiveStorageAttachedPatch::BlobChecksumPatch)
      ::ActiveStorage::Blob.singleton_class.prepend(ActiveStorageAttachedPatch::BlobBuildPatch)
      # Ensure `ActiveStorage::Blob#metadata` is a serialized store attribute even
      # when the class is freshly autoloaded in a worker Ractor's empty constant
      # namespace. `store :metadata` registers a `Type::Serialized` decorator via
      # `decorate_attributes`, but the decorator is only applied to attributes that
      # already exist in `cast_types` — and `cast_types` is built lazily from the
      # DB `columns_hash`. If the class is loaded before the worker's DB connection
      # is established, `columns_hash` (and thus `cast_types`) is empty, so the
      # `:metadata` decorator is silently skipped and `store_accessor_for` later
      # raises "the column 'metadata' has not been configured as a store". Force
      # the serialized type for `:metadata` directly so `write_store_attribute`
      # works in the worker regardless of load-order.
      ::ActiveStorage::Blob.singleton_class.prepend(ActiveStorageAttachedPatch::BlobMetadataTypePatch)
      ::ActiveStorage::Blob.prepend(ActiveStorageAttachedPatch::ActiveStorageServicePatch)
      @_as_patched_blob = true
    end

    # `ActiveStorage::Blob#metadata` is declared via `store :metadata, coder:
    # ActiveRecord::Coders::JSON`, which registers a `Type::Serialized` cast
    # type through `decorate_attributes` (a lazily-memoized `PendingDecorator`).
    # `decorate_attributes` only resets `@default_attributes`, NOT the separately
    # memoized `@attribute_types` — so if `@attribute_types` was primed as a
    # plain `Type::Text`/`Type::Value` by an earlier attribute access during
    # class load (which happens when the class is freshly autoloaded in a worker
    # Ractor's empty constant namespace), the decorated (Serialized) type is
    # never recomputed and `write_store_attribute` later raises "the column
    # 'metadata' has not been configured as a store". Patch `decorate_attributes`
    # to also invalidate `@attribute_types` so the decorated type is picked up.
    def _install_as_attribute_types_cache_reset!
      return if @_as_attr_types_reset_installed
      @_as_attr_types_reset_installed = true
      return unless defined?(::ActiveRecord::Base)
      ::ActiveRecord::Base.singleton_class.prepend(Module.new do
        def decorate_attributes(names = nil, &decorator)
          super
          instance_variable_set(:@attribute_types, nil)
        rescue StandardError
          super
        end
      end)
    end

    # Seed the shareable ActiveStorage table-name prefix/suffix constants from
    # the (main-ractor) `ActiveStorage.table_name_prefix` value. Must run in the
    # main Ractor at prepare_for_ractors! time, after ActiveStorage is fully
    # loaded. Workers read these constants (never the un-shareable mattr reader).
    def _seed_active_storage_prefix!
      return unless defined?(::ActiveStorage) && ::ActiveStorage.respond_to?(:table_name_prefix)
      # The reader was redefined to return the shareable constant, so read the
      # ORIGINAL value from `ActiveStorage`'s `@@table_name_prefix` class
      # variable (the mattr_accessor store) in main — callable from the main
      # Ractor, unlike the un-shareable mattr reader from a worker.
      prefix = if ::ActiveStorage.class_variable_defined?(:@@table_name_prefix)
        ::ActiveStorage.class_variable_get(:@@table_name_prefix).to_s
      else
        "active_storage_"
      end
      suffix = if ::ActiveStorage.class_variable_defined?(:@@table_name_suffix)
        ::ActiveStorage.class_variable_get(:@@table_name_suffix).to_s
      else
        ""
      end
      RactorRailsShim.const_set(:ACTIVE_STORAGE_PREFIX, prefix.freeze)
      RactorRailsShim.const_set(:ACTIVE_STORAGE_SUFFIX, suffix.freeze)
      # Reset the cached `table_name` on ActiveStorage models so they recompute
      # with the correct prefix/suffix. Without this, `ActiveStorage::Blob`'s
      # `table_name` stays `"blobs"` (computed at eager-load with the empty
      # prefix) instead of `"active_storage_blobs"`. Set explicitly to avoid
      # going through `reset_table_name` (which may fail in edge cases).
      if defined?(::ActiveStorage::Blob)
        ::ActiveStorage::Blob.table_name = "#{prefix}blobs#{suffix}"
      end
      if defined?(::ActiveStorage::Attachment)
        ::ActiveStorage::Attachment.table_name = "#{prefix}attachments#{suffix}"
      end
    end

    # Force-rebuild `ActiveStorage::Blob`'s `_default_attributes` and
    # `@attribute_types` in MAIN so the `:metadata` attribute uses the correct
    # `Type::Serialized` before the graph is frozen. The `store :metadata`
    # decorator registers a `Type::Serialized` via `decorate_attributes`, but
    # `@attribute_types` is memoized separately and isn't invalidated when the
    # decorator runs — so it keeps a stale `Type::Value`. `read_attribute` uses
    # the attribute set (not `type_for_attribute`), so the stale type makes
    # `read_attribute(:metadata)` return a raw String instead of a deserialized
    # Hash, breaking `write_store_attribute` and `identified=` in workers.
    # Must run in the main Ractor (writes class ivars).
    def _fix_blob_metadata_type!
      return unless defined?(::ActiveStorage::Blob) && ::Ractor.main?
      blob_cls = ::ActiveStorage::Blob
      # Directly fix the attribute set: replace the :metadata attribute's type
      # with Type::Serialized. The `store :metadata` decorator was applied
      # once during eager-load but only to the (now stale) `_default_attributes`
      # cache. Re-register the decorator and rebuild from scratch.
      attrs = blob_cls._default_attributes
      meta_attr = attrs[:metadata]
      if meta_attr && !meta_attr.type.is_a?(::ActiveRecord::Type::Serialized)
        # Re-run the serialize decorator for :metadata. The original `store
        # :metadata, coder: ActiveRecord::Coders::JSON` uses
        # `build_column_serializer` which instantiates `Coders::JSON.new`
        # (the class itself doesn't respond to dump/load). Reproduce that here.
        coder = ::ActiveRecord::Coders::JSON.new
        ind_coder = ::ActiveRecord::Store::IndifferentCoder.new(:metadata, coder)
        meta_type = ::ActiveRecord::Type::Serialized.new(meta_attr.type, ind_coder)
        # Fix BOTH the string and symbol key entries (the attribute set has
        # both "metadata" and :metadata — read_attribute uses the string key,
        # which has the wrong Type::Text).
        attrs[:metadata] = meta_attr.with_type(meta_type)
        string_attr = attrs["metadata"]
        if string_attr && !string_attr.type.is_a?(::ActiveRecord::Type::Serialized)
          attrs["metadata"] = string_attr.with_type(meta_type)
        end
        # Clear the stale @attribute_types cache so it's rebuilt with the
        # corrected type from the updated attribute set.
        blob_cls.remove_instance_variable(:@attribute_types) if blob_cls.instance_variable_defined?(:@attribute_types)
      end
    end
  end
end
