# frozen_string_literal: true

# `ActiveRecord::SecureToken.has_secure_token` registers its generation logic
# as a BLOCK callback:
#
#   set_callback on, :before do
#     if new_record? && !query_attribute(attribute)
#       send("#{attribute}=", self.class.generate_unique_secure_token(length: length))
#     end
#   end
#
# `SymbolicTransport` replays only Symbol-named filters in worker Ractors —
# block filters are fail-safe skipped (they are main-compiled Procs). So a
# worker-created row got NO generated token: ActiveStorage's direct-upload
# endpoint (row 121) died with
#   PG::NotNullViolation: null value in column "key" of relation
#   "active_storage_blobs"
#
# Fix: wrap the macro so that AFTER the upstream (block) registration we also
# register an equivalent NAMED callback. In main the block runs first and
# generates the token, so the named one sees the attribute set and skips — no
# double generation. In workers the block is skipped and the named callback
# (a shareable `def`) generates the token, matching main semantics.
# Install-time hook (on_load :active_record), so every model calling
# `has_secure_token` at boot — ActiveStorage::Blob is the one in this audit —
# gets the worker-safe registration.

module RactorRailsShim
  module Patches
    module SecureTokenPatch
      module_function

      def apply!
        unless @applied
          @applied = true
          RactorRailsShim.__send__(:_register_patch, :secure_token, "8.1")
        end
        patch_macro!
        reapply_existing!
        true
      end

      # Models loaded BEFORE the macro patch (ActiveStorage::Blob loads while
      # the shim's own loader requires active_storage) already registered the
      # upstream BLOCK callback. Find those callbacks (their source file is
      # active_record/secure_token.rb) and re-run the patched macro for the
      # same attribute — the block stays (main semantics unchanged) and the
      # Symbol callback gets added for workers. Idempotent: repeat dispatches
      # (prepare_for_ractors!, make_app_shareable!) find no new block.
      def reapply_existing!
        return true unless defined?(::ActiveRecord::Base)
        classes = []
        classes.concat(::ActiveRecord::Base.descendants) rescue nil
        classes.each do |klass|
          already = {}
          %i[initialize create save update].each do |chain|
            callbacks = klass.__callbacks[chain] rescue nil
            next unless callbacks
            callbacks.each do |cb|
              filter = cb.filter
              next unless filter.is_a?(::Proc)
              loc = (filter.source_location rescue nil)&.first.to_s
              next unless loc.end_with?("active_record/secure_token.rb")
              attribute = filter.binding.local_variable_get(:attribute) rescue nil
              next unless attribute
              next if already[attribute]
              already[attribute] = true
              next if klass.private_method_defined?(:"__ractors_generate_secure_#{attribute}") ||
                klass.method_defined?(:"__ractors_generate_secure_#{attribute}")
              length = filter.binding.local_variable_get(:length) rescue nil
              begin
                klass.has_secure_token(attribute, length: length, on: chain)
              rescue StandardError
                nil
              end
            end
          end
        end
        true
      end

      def patch_macro!
        # Force the autoload: at install time active_record may be loaded
        # before ActiveSupport::Concern is, so the require can legitimately
        # fail — the next dispatch (prepare_for_ractors!) retries, before the
        # app's models are eager-loaded.
        unless defined?(::ActiveRecord::SecureToken::ClassMethods)
          # Requiring the file before ActiveSupport::Concern is available leaves
          # a HALF-DEFINED ActiveRecord::SecureToken module behind (the extend
          # raises after the module opens), which breaks `has_secure_token`
          # autoloading for every model. Never attempt it that early — the next
          # dispatch (prepare_for_ractors!, post-boot) retries.
          return true unless defined?(ActiveSupport::Concern)
          begin
            require "active_record/secure_token"
          rescue StandardError, LoadError
            return true
          end
        end
        return true unless defined?(::ActiveRecord::SecureToken::ClassMethods)
        cm = ::ActiveRecord::SecureToken::ClassMethods
        src = cm.instance_method(:has_secure_token).source_location&.first.to_s
        return true if src.end_with?("ractor_rails_shim/patches/secure_token.rb")

        cm.module_eval(<<-'RUBY', __FILE__, __LINE__ + 1)
          alias_method :__rrs_original_has_secure_token, :has_secure_token

          def has_secure_token(attribute = :token, length: nil, on: nil)
            length ||= ::ActiveRecord::SecureToken::MINIMUM_TOKEN_LENGTH
            on ||= ::ActiveRecord.generate_secure_token_on
            __rrs_original_has_secure_token(attribute, length: length, on: on)

            callback_name = "__ractors_generate_secure_#{attribute}"
            class_eval(<<-EOS, __FILE__, __LINE__ + 1)
              def #{callback_name}
                if new_record? && !query_attribute(#{attribute.inspect})
                  send("#{attribute}=", self.class.generate_unique_secure_token(length: #{length}))
                end
              end
              private :#{callback_name}
            EOS
            set_callback on, on == :initialize ? :after : :before, callback_name.to_sym
          end
        RUBY
        true
      end
    end
  end

  def self._install_secure_token_patch = Patches::SecureTokenPatch.apply!
end
