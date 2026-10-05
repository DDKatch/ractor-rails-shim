# frozen_string_literal: true

module RactorRailsShim
  # CGI::Escape (stdlib cgi) seeds its default decoding charset in a CLASS
  # VARIABLE (@@accept_charset = Encoding::UTF_8). Ruby forbids ANY access to
  # class variables from non-main Ractors —
  #   Ractor::IsolationError: can not access class variables from non-main
  #   Ractors (@@accept_charset from #<Class:CGI>)
  # — even when the value itself is shareable. The offending uses are the
  # DEFAULT ARGUMENTS of CGI::Escape#unescape / #unescapeURIComponent
  # (`encoding = @@accept_charset`), which are evaluated at call time — so a
  # worker Ractor crashes the moment anything URL-decodes. globalid hits this
  # from GlobalID/URI::GID parsing, which puts it on the ActiveJob enqueue
  # path (perform_later / deliver_later from a worker — shim TODO #5).
  #
  # Fix: re-define both methods via string eval (shareable defs, no captured
  # bindings) defaulting to a frozen snapshot of the class variable captured
  # at patch time (Encoding objects are Ractor-shareable). The class variable
  # itself is left untouched, so main-Ractor callers and anything that mutates
  # CGI.accept_charset semantics keeps working off the original storage.
  module CGIPatch
    module_function

    def apply!
      require "cgi/escape"
      return if @patched
      @patched = true
      RactorRailsShim.__send__(:_register_patch, :cgi, "8.1")

      snapshot = capture_accept_charset
      install_snapshot_constant!(snapshot)
      patch_escape_methods!
    end

    # Snapshot the class variable in the MAIN Ractor (workers may never read
    # it). Falls back to the stdlib's own seed value (Encoding::UTF_8) if the
    # variable is somehow undefined.
    def capture_accept_charset
      if ::CGI::Escape.class_variable_defined?(:@@accept_charset)
        ::CGI::Escape.class_variable_get(:@@accept_charset)
      else
        ::Encoding::UTF_8
      end
    end

    def install_snapshot_constant!(encoding)
      value = Ractor.make_shareable(encoding)
      RactorRailsShim._reassign_shareable_const(:CGI_ACCEPT_CHARSET, value)
    end

    # Bodies copied verbatim from the stdlib (Ruby 4.0 cgi/escape.rb); only
    # the default-argument expression differs (frozen snapshot constant
    # instead of the class variable).
    #
    # Two targets: CGI::Escape (pure Ruby) AND CGI::EscapeExt (the C ext from
    # cgi/escape.so, which re-defines unescape/unescapeURIComponent and
    # shadows Escape in CGI's ancestor chain — its C impl also reads
    # @@accept_charset internally when the encoding argument is omitted).
    # Overriding a C method with a Ruby def on the same module is fine.
    def patch_escape_methods!
      escape_body = lambda do
        <<~RUBY
          def unescape(string, encoding = RactorRailsShim::CGI_ACCEPT_CHARSET)
            str = string.tr('+', ' ')
            str = str.b
            str.gsub!(/((?:%[0-9a-fA-F]{2})+)/) do |m|
              [m.delete('%')].pack('H*')
            end
            str.force_encoding(encoding)
            str.valid_encoding? ? str : str.force_encoding(string.encoding)
          end

          def unescapeURIComponent(string, encoding = RactorRailsShim::CGI_ACCEPT_CHARSET)
            str = string.b
            str.gsub!(/((?:%[0-9a-fA-F]{2})+)/) do |m|
              [m.delete('%')].pack('H*')
            end
            str.force_encoding(encoding)
            str.valid_encoding? ? str : str.force_encoding(string.encoding)
          end

          alias_method :unescape_uri_component, :unescapeURIComponent
        RUBY
      end

      targets = [::CGI::Escape]
      targets << ::CGI::EscapeExt if defined?(::CGI::EscapeExt)
      targets.each { |target| target.module_eval escape_body.call, __FILE__, __LINE__ + 1 }
    end
  end

  def self._install_cgi_patch = CGIPatch.apply!
end
