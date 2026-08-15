# frozen_string_literal: true

module RactorRailsShim
  # `ActiveRecord::Store` generates its accessors and store-coder resolution with
  # un-shareable blocks compiled in the main Ractor. A worker Ractor that writes a
  # store accessor (e.g. `ActiveStorage::Blob#identified=`) raises "defined with an
  # un-shareable Proc in a different Ractor".
  #
  # We re-implement the two offending methods with block-free equivalents:
  #   * `store_accessor` (ClassMethods) — emits the accessor method bodies via
  #     string-eval `def`s instead of `define_method` blocks.
  #   * `store_accessor_for` (Store module instance method) — resolves the coder
  #     without the `tap do |type| ... end` block.
  #
  # Both must be installed BEFORE any model that uses `store` (e.g.
  # ActiveStorage::Blob) is loaded, so accessors are generated in shareable form
  # from the start.
  module ActiveRecordStorePatch
    # `ActiveRecord::Store::ClassMethods#store_accessor` generates each store
    # accessor (getter, setter, `_changed?`, `_change`, `_was`, `saved_change_to_*`,
    # `_before_last_save`) via `define_method` inside a `module_eval` block. Those
    # `define_method` blocks are compiled in the main Ractor, so any worker Ractor
    # that calls a store accessor (e.g. `ActiveStorage::Blob#identified=`) blows
    # up with "defined with an un-shareable Proc in a different Ractor".
    #
    # We re-implement `store_accessor` to emit the same method bodies with
    # string-eval `def`s (no closures / no blocks), which are Ractor-shareable.
    def store_accessor(store_attribute, *keys, prefix: nil, suffix: nil)
      keys = keys.flatten

      accessor_prefix =
        case prefix
        when String, Symbol
          "#{prefix}_"
        when TrueClass
          "#{store_attribute}_"
        else
          ""
        end
      accessor_suffix =
        case suffix
        when String, Symbol
          "_#{suffix}"
        when TrueClass
          "_#{store_attribute}"
        else
          ""
        end

      mod = _store_accessors_module
      sa = store_attribute.inspect
      mod.class_eval do
        keys.each do |key|
          accessor_key = "#{accessor_prefix}#{key}#{accessor_suffix}"
          key_lit = key.inspect
          class_eval <<-RUBY, __FILE__, __LINE__ + 1
            def #{accessor_key}=(value)
              write_store_attribute(#{sa}, #{key_lit}, value)
            end

            def #{accessor_key}
              read_store_attribute(#{sa}, #{key_lit})
            end

            def #{accessor_key}_changed?
              return false unless attribute_changed?(#{sa})
              prev_store, new_store = changes[#{sa}]
              accessor = store_accessor_for(#{sa})
              accessor.get(prev_store, #{key_lit}) != accessor.get(new_store, #{key_lit})
            end

            def #{accessor_key}_change
              return unless attribute_changed?(#{sa})
              prev_store, new_store = changes[#{sa}]
              accessor = store_accessor_for(#{sa})
              [accessor.get(prev_store, #{key_lit}), accessor.get(new_store, #{key_lit})]
            end

            def #{accessor_key}_was
              return unless attribute_changed?(#{sa})
              prev_store, _new_store = changes[#{sa}]
              accessor = store_accessor_for(#{sa})
              accessor.get(prev_store, #{key_lit})
            end

            def saved_change_to_#{accessor_key}?
              return false unless saved_change_to_attribute?(#{sa})
              prev_store, new_store = saved_changes[#{sa}]
              accessor = store_accessor_for(#{sa})
              accessor.get(prev_store, #{key_lit}) != accessor.get(new_store, #{key_lit})
            end

            def saved_change_to_#{accessor_key}
              return unless saved_change_to_attribute?(#{sa})
              prev_store, new_store = saved_changes[#{sa}]
              accessor = store_accessor_for(#{sa})
              [accessor.get(prev_store, #{key_lit}), accessor.get(new_store, #{key_lit})]
            end

            def #{accessor_key}_before_last_save
              return unless saved_change_to_attribute?(#{sa})
              prev_store, _new_store = saved_changes[#{sa}]
              accessor = store_accessor_for(#{sa})
              accessor.get(prev_store, #{key_lit})
            end
          RUBY
        end
      end

      self.local_stored_attributes ||= {}
      self.local_stored_attributes[store_attribute] ||= []
      self.local_stored_attributes[store_attribute] |= keys
    end
  end

  # `ActiveRecord::Store#store_accessor_for` resolves the store coder via
  # `type_for_attribute(store_attribute).tap do |type| ... end`. The `tap` block
  # is compiled in the main Ractor and is un-shareable, so a worker Ractor raises
  # "defined with an un-shareable Proc in a different Ractor" when writing any
  # store accessor (e.g. `ActiveStorage::Blob#identified=`). Reimplement without
  # the block. This is an instance method of the `ActiveRecord::Store` module, so
  # it is prepended to `ActiveRecord::Store` itself.
  module ActiveRecordStoreInstancePatch
    def store_accessor_for(store_attribute)
      type = type_for_attribute(store_attribute)
      unless type.respond_to?(:accessor)
        raise ConfigurationError, "the column '#{store_attribute}' has not been configured as a store. Please make sure the column is declared serializable via 'ActiveRecord.store' or, if your database supports it, use a structured column type like hstore or json."
      end
      type.accessor
    end

    # `ActiveRecord::Store::HashAccessor#write` mutates the hash returned by
    # `object.<attribute>` and relies on that read returning a *cached, mutable*
    # object so the mutation is reflected on later reads. In a worker Ractor the
    # serialized attribute read is not cached (each read re-deserializes), so the
    # in-place mutation is lost and store accessors such as
    # `ActiveStorage::Blob#identified=` silently fail to persist. Re-implement
    # `write_store_attribute` to read the current value, merge the key, and write
    # it back through `write_attribute` — which always persists regardless of
    # whether the deserialized read is cached. Store accessors use string keys,
    # so the key is normalized with `to_s`.
    def write_store_attribute(store_attribute, key, value)
      current = read_attribute(store_attribute)
      current = current ? current.dup : {}
      current[key.to_s] = value
      write_attribute(store_attribute, current)
    end
  end

  def self._install_active_record_store_patch
    return if @active_record_store_patched
    @active_record_store_patched = true
    # `ActiveRecord::Store` may not be loaded yet when this runs in a worker
    # Ractor (separate process) where ActiveRecord::Base is not defined at
    # install time. Force-load it so we can prepend BEFORE any model
    # (e.g. ActiveStorage::Blob) calls `store`, which generates the accessors
    # at class-definition time. Requiring it here is idempotent and harmless
    # for apps that don't use ActiveRecord.
    begin
      require "active_record/store"
    rescue LoadError
      return
    end
    return unless defined?(::ActiveRecord::Store::ClassMethods)
    ::ActiveRecord::Store::ClassMethods.prepend(ActiveRecordStorePatch)
    ::ActiveRecord::Store.prepend(ActiveRecordStoreInstancePatch)
    _register_patch :active_record_store, "8.1"
  end
end
