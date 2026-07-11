# frozen_string_literal: true

# Patches for OpenSSL digest classes so they can be used from worker Ractors.
#
# `openssl/digest.rb` defines each algorithm class (SHA256, etc.) as:
#
#   klass = Class.new(self) {
#     define_method(:initialize, ->(data = nil) { super(name, data) })
#   }
#   singleton.class_eval {
#     define_method(:digest)    { |data| new.digest(data) }
#     define_method(:hexdigest) { |data| new.hexdigest(data) }
#   }
#
# The `->(data = nil) { ... }` lambda (and the singleton `digest`/`hexdigest`
# blocks) are compiled in the MAIN Ractor. Instantiating the class from a
# worker Ractor (`OpenSSL::Digest::SHA256.new`, called e.g. by
# `ActiveSupport::KeyGenerator#generate_key` -> `OpenSSL::PKCS5.pbkdf2_hmac`
# -> `@hash_digest_class.new`) invokes that lambda and raises
# "defined with an un-shareable Proc in a different Ractor". This blocks every
# request that touches the cookie/session key generator (i.e. all of them).
#
# Fix: redefine the methods with string-eval (no captured binding) so they are
# callable from any Ractor. Behaviour is identical. Applied at
# prepare_for_ractors! time (after OpenSSL is loaded).

module RactorRailsShim
  class << self
    def _install_openssl_digest_patch
      return if @openssl_digest_patched
      @openssl_digest_patched = true
      _register_patch :openssl_digest, "8.1"
      return unless defined?(::OpenSSL::Digest)

      algos = %w(MD4 MD5 RIPEMD160 SHA1 SHA224 SHA256 SHA384 SHA512)
      algos.each do |name|
        klass_name = name.tr("-", "_")
        next unless ::OpenSSL::Digest.const_defined?(klass_name)
        klass = ::OpenSSL::Digest.const_get(klass_name)
        next unless klass.is_a?(::Class)

        # Replace the lambda-based `initialize` (super(name, data)) with a
        # string-eval'd method that holds no captured Proc.
        klass.class_eval "def initialize(data = nil); super(#{name.inspect}, data); end"

        # Replace the singleton `digest`/`hexdigest` blocks the same way.
        klass.singleton_class.class_eval <<-RUBY, __FILE__, __LINE__ + 1
          def digest(data)
            new.digest(data)
          end
          def hexdigest(data)
            new.hexdigest(data)
          end
        RUBY
      end
    end
  end
end
