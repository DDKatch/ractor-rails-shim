# frozen_string_literal true

# Patches for the `mail` gem (a transitive dependency of ActionMailer).
#
# The `mail` gem stores global state in raw class variables (`@@default_charset`,
# `@@maximum_amount`, `@@delivery_interceptors`, `@@delivery_notification_observers`,
# `@@uniq`, `@@deliveries`) and reads/writes them directly (often inline, not via
# an accessor). From a non-main Ractor these raise `Ractor::IsolationError`
# ("can not access class variables from non-main Ractors"). The shim's
# `mattr_accessor` / `class_attribute` rewrites don't cover the `mail` gem because
# it uses raw `@@cvar`s, not those macros.
#
# Fix: route each cvar-backed accessor / call site through
# `ActiveSupport::IsolatedExecutionState` (IES), which is per-Ractor (each worker
# builds its own copy). Main Ractor keeps the real cvar; workers read a per-Ractor
# IES slot (seeded lazily with the documented default). This lets a worker Ractor
# build + render + deliver a mailer message off the frozen shared graph.

  module RactorRailsShim
    class << self
    def _install_mail_patch
      return if @mail_patched
      @mail_patched = true
      _register_patch :mail, "8.1"
      return unless defined?(::Mail)

      # --- Mail::Message.default_charset (read in Mail::Message#initialize) ---
      if defined?(::Mail::Message)
        ::Mail::Message.singleton_class.class_eval do
          def default_charset
            if ::Ractor.main?
              @@default_charset
            else
              ::RactorRailsShim.storage[:ractor_rails_shim_mail_default_charset] || "UTF-8"
            end
          end

          def default_charset=(charset)
            if ::Ractor.main?
              @@default_charset = charset
              ::RactorRailsShim.storage[:ractor_rails_shim_mail_default_charset] = charset
            else
              ::RactorRailsShim.storage[:ractor_rails_shim_mail_default_charset] = charset
            end
          end
        end
      end

      # --- Mail::Header.maximum_amount (read while parsing/building headers) ---
      if defined?(::Mail::Header)
        ::Mail::Header.singleton_class.class_eval do
          def maximum_amount
            if ::Ractor.main?
              @@maximum_amount
            else
              ::RactorRailsShim.storage[:ractor_rails_shim_mail_max_amount] || 1000
            end
          end

          def maximum_amount=(value)
            if ::Ractor.main?
              @@maximum_amount = value
              ::RactorRailsShim.storage[:ractor_rails_shim_mail_max_amount] = value
            else
              ::RactorRailsShim.storage[:ractor_rails_shim_mail_max_amount] = value
            end
          end
        end
      end

      # --- ActionMailer::Base.mailer_name (raw class ivar on the mailer subclass) ---
      # `mailer_name` (aliased to `controller_path`) computes the mailer's view
      # path prefix from its class name, but reads the lazy `@mailer_name` class
      # ivar — unreadable from a worker Ractor. The value defaults to
      # `name.underscore`, which is derivable from the (shareable) class name, so
      # just compute it in workers.
      if defined?(::ActionMailer::Base)
        _install_actionmailer_mailer_name_patch
      elsif defined?(::ActiveSupport.on_load)
        # ActionMailer not loaded yet (e.g. shim `install` runs before
        # `require "rails/all"`). Register the patch to fire the moment
        # ActionMailer::Base is loaded — BEFORE the app eager-loads its mailers,
        # so the `local_prefixes` -> `[controller_path]` -> `mailer_name` call
        # sites compile against the patched method (a late `prepare_for_ractors!`
        # patch binds too late: those call sites have already captured the
        # original `@mailer_name`-reading method).
        ::ActiveSupport.on_load(:action_mailer) do
          RactorRailsShim.send(:_install_actionmailer_mailer_name_patch)
        end
      end

      # --- Freeze all un-shareable `mail` gem constants so workers can read them ---
      # The `mail` gem defines many Regexp / mutable-Array / mutable-Hash module
      # constants (e.g. Mail::Utilities::TO_CRLF_REGEX, Mail::SMTP::DEFAULTS).
      # Reading an un-shareable constant from a non-main Ractor raises
      # IsolationError, so make every constant value under `Mail` shareable (in
      # place — freezing Regexps/Arrays/Hashes). Done once at install; constants
      # are fixed at boot so freezing after boot is safe.
      if defined?(::Mail)
        _make_mail_constants_shareable!
      end

      # --- Mail::Encodings registry (a module ivar, read during message build) ---
      # `Mail::Encodings.@transfer_encodings` is a module-level ivar holding the
      # registered transfer encodings (base64, quoted_printable, ...). Reading it
      # from a worker Ractor raises IsolationError. The registry is fixed at boot,
      # so capture a frozen shareable copy and have workers read it.
      if defined?(::Mail::Encodings)
        enc_reg = nil
        begin
          enc_reg = ::Mail::Encodings.instance_variable_get(:@transfer_encodings)
        rescue StandardError
          enc_reg = nil
        end
        if enc_reg
          RactorRailsShim.const_set(
            :SHAREABLE_MAIL_TRANSFER_ENCODINGS,
            Ractor.make_shareable(enc_reg.dup)
          )
        end
        ::Mail::Encodings.singleton_class.class_eval do
          def get_encoding(name)
            reg = ::Ractor.main? ? @transfer_encodings : ::RactorRailsShim::SHAREABLE_MAIL_TRANSFER_ENCODINGS
            reg[get_name(name)]
          end

          def get_all
            reg = ::Ractor.main? ? @transfer_encodings : ::RactorRailsShim::SHAREABLE_MAIL_TRANSFER_ENCODINGS
            reg.values
          end

          def defined?(name)
            reg = ::Ractor.main? ? @transfer_encodings : ::RactorRailsShim::SHAREABLE_MAIL_TRANSFER_ENCODINGS
            reg.include? get_name(name)
          end
        end
      end

      # --- Mail.delivery_method (resolves Mail::Configuration, a Singleton) ---
      # `Mail.delivery_method` calls `Mail::Configuration.instance` — a Singleton
      # whose class ivar (`@singleton__mutex__`) is un-shareable, so reading it
      # from a worker Ractor raises IsolationError. Capture the RESOLVED
      # delivery-method CLASS at install (main) into a shareable constant; workers
      # build a fresh, worker-local instance of it instead of touching the
      # Singleton. The `:test` delivery instance only appends to
      # `TestMailer.deliveries` (class-level, patched above), so a fresh instance
      # per call is correct.
      dm_class = nil
      begin
        resolved = ::Mail::Configuration.instance.delivery_method
        dm_class = resolved.class if resolved
      rescue StandardError
        dm_class = nil
      end
      if dm_class
        RactorRailsShim.const_set(
          :SHAREABLE_MAIL_DELIVERY_METHOD_CLASS,
          Ractor.make_shareable(dm_class)
        )
      end
      ::Mail.singleton_class.class_eval do
        alias_method :_rrs_orig_delivery_method, :delivery_method
        def delivery_method(method = nil, settings = {})
          if ::Ractor.main?
            _rrs_orig_delivery_method(method, settings)
          else
            klass = ::RactorRailsShim::SHAREABLE_MAIL_DELIVERY_METHOD_CLASS
            return klass.new(settings) if klass
            _rrs_orig_delivery_method(method, settings)
          end
        end
      end

      # --- Mail::Configuration.instance (a Singleton) ---
      # `Mail::Message#delivery_method` calls `Mail::Configuration.instance`
      # directly. The Singleton's `instance` reads the un-shareable class ivar
      # `@singleton__instance__`, which raises IsolationError in a worker Ractor.
      # Build a fresh, worker-local Configuration instance instead (the Singleton
      # makes `new` private, so use `allocate` + `initialize`). A fresh instance
      # is correct: delivery settings are derived per-call from the method name.
      if defined?(::Mail::Configuration)
        unless ::Mail::Configuration.singleton_class.private_instance_methods
                .include?(:_rrs_orig_configuration_instance)
          ::Mail::Configuration.singleton_class.class_eval do
            alias_method :_rrs_orig_configuration_instance, :instance
          end
        end
        ::Mail::Configuration.singleton_class.class_eval do
          def instance
            if ::Ractor.main?
              _rrs_orig_configuration_instance
            else
              cfg = ::Mail::Configuration.send(:allocate)
              cfg.send(:initialize)
              cfg
            end
          end
        end
      end

      # --- Mail delivery observers / interceptors ---
      # `inform_interceptors` / `inform_observers` read `@@delivery_interceptors`
      # / `@@delivery_notification_observers` INLINE (not via the reader), so the
      # readers alone don't help. Patch the call sites to read the per-Ractor IES
      # slot. Workers have no registered observers/interceptors, so an empty array
      # is correct.
      ::Mail.singleton_class.class_eval do
        def inform_interceptors(mail_obj)
          interceptors = if ::Ractor.main?
            @@delivery_interceptors
          else
            ::RactorRailsShim.storage[:ractor_rails_shim_mail_interceptors] ||= []
          end
          interceptors.each { |i| i.delivering_email(mail_obj) }
        end

        def inform_observers(mail_obj)
          observers = if ::Ractor.main?
            @@delivery_notification_observers
          else
            ::RactorRailsShim.storage[:ractor_rails_shim_mail_observers] ||= []
          end
          observers.each { |o| o.delivered_email(mail_obj) }
        end

        # `uniq` does `@@uniq += 1` (a cvar WRITE) — also illegal in workers.
        # Use a per-Ractor IES counter instead.
        def uniq
          if ::Ractor.main?
            @@uniq += 1
          else
            n = (::RactorRailsShim.storage[:ractor_rails_shim_mail_uniq] || 0) + 1
            ::RactorRailsShim.storage[:ractor_rails_shim_mail_uniq] = n
            n
          end
        end
      end

      # --- Mail::TestMailer.deliveries (ActionMailer's :test delivery appends here) ---
      if defined?(::Mail::TestMailer)
        ::Mail::TestMailer.singleton_class.class_eval do
          def deliveries
            if ::Ractor.main?
              @@deliveries ||= []
            else
              ::RactorRailsShim.storage[:ractor_rails_shim_mail_test_deliveries] ||= []
            end
          end

          def deliveries=(val)
            if ::Ractor.main?
              @@deliveries = val
              ::RactorRailsShim.storage[:ractor_rails_shim_mail_test_deliveries] = val
            else
              ::RactorRailsShim.storage[:ractor_rails_shim_mail_test_deliveries] = val
            end
          end
        end
      end

      # --- Mail::Parsers::*Parser class ivars (Citrus/Ragel parse tables) ---
      # The `mail` gem's generated parsers (MimeVersionParser, AddressParser, …)
      # are MODULES whose `class << self` block stores parse tables as singleton
      # ivars (`@_index_offsets`, `@_trans_keys`, `@_key_spans`, …). These are
      # populated at file-load time and are deterministic/shareable once frozen,
      # but reading a class/module ivar from a non-main Ractor raises
      # IsolationError. Capture each value once (in the main Ractor) and redefine
      # the attr reader to return the captured, shareable copy — so worker calls
      # to `_index_offsets` / `_trans_keys` / … return the same table.
      # --- Module-level ivars on `mail` gem modules (Citrus/Ragel parse tables,
      # `Mail::Utilities#charset_encoder`, …) ---
      # These modules store state as class/module ivars (`@_index_offsets`,
      # `@_trans_keys`, `@charset_encoder`, …) populated at file-load time.
      # Reading a module ivar from a non-main Ractor raises IsolationError, so
      # capture each value once (in the main Ractor) into a shareable constant
      # and redefine the attr reader to return the captured copy (via
      # string-eval `def` — NOT `define_method`, whose block would be an
      # un-shareable Proc). This covers `Mail::Parsers::*Parser` and
      # `Mail::Utilities` (which uses `attr_accessor :charset_encoder`).
      target_modules = []
      if defined?(::Mail::Parsers)
        ::Mail::Parsers.constants(false).each do |pname|
          pmod = ::Mail::Parsers.const_get(pname) rescue nil
          target_modules << pmod if pmod.is_a?(Module)
        end
      end
      target_modules << ::Mail::Utilities if defined?(::Mail::Utilities)
      target_modules.each do |pmod|
        ivs = pmod.instance_variables
        next if ivs.empty?
        captured = {}
        ivs.each do |iv|
          val = pmod.instance_variable_get(iv) rescue nil
          captured[iv] = ::Ractor.make_shareable(val) rescue val
        end
        captured.freeze
        const_name = :RRS_MODULE_IVARS
        unless pmod.singleton_class.const_defined?(const_name)
          pmod.singleton_class.const_set(const_name, captured)
        end
        pmod.singleton_class.class_eval do
          captured.each do |iv, val|
            reader = iv.to_s.sub(/\A@/, "").to_sym
            if method_defined?(reader, true) && !val.nil?
              class_eval(<<~RUBY)
                def #{reader}
                  ::#{pmod}.singleton_class::#{const_name}[#{iv.inspect}]
                end
              RUBY
            end
          end
        end
      end
      # --- Mail::PartsList / Mail::AttachmentsList (DelegateClass(Array)) ---
      # `DelegateClass(Array)` generates each delegating method (`[]`, `<<`, `each`,
      # …) via a block compiled in the main Ractor, so the methods are un-shareable
      # Procs that raise "defined with an un-shareable Proc in a different Ractor"
      # when called from a worker Ractor (hit during message building:
      # `Mail::Body#<<` -> `Mail::PartsList.new[val]`). Redefine the delegating
      # methods as string-eval `def`s (shareable) that forward to `__getobj__` —
      # identical behavior to DelegateClass, but callable from any Ractor. We skip
      # methods the class defines itself (e.g. `PartsList#collect`) so we don't
      # clobber their (already shareable) custom implementations.
      if defined?(::Mail::PartsList) || defined?(::Mail::AttachmentsList)
        [::Mail::PartsList, ::Mail::AttachmentsList].each do |klass|
          next unless klass.is_a?(Class)
          # `DelegateClass` also compiles `__getobj__` / `__setobj__` (and the
          # inherited `initialize`, which calls `__setobj__`) as Procs in the main
          # Ractor, so redefine those shareably too. The backing ivar is
          # `@delegate_dc_obj` (verified against Ruby's DelegateClass).
          klass.class_eval(<<~RUBY)
            def __getobj__
              @delegate_dc_obj
            end

            def __setobj__(obj)
              @delegate_dc_obj = obj
            end

            # Shadow the DelegateClass-generated `initialize` (a Proc compiled in
            # the main Ractor). Reproduce PartsList's own init: build the backing
            # Array and point the delegation ivar at it directly, so `super` never
            # reaches the un-shareable DelegateClass constructor.
            def initialize(*args)
              @parts = Array.new(*args)
              @delegate_dc_obj = @parts
            end
          RUBY
          ::Array.instance_methods(false).each do |m|
            next if %i[object_id __send__ __id__ equal?].include?(m)
            im = klass.instance_method(m) rescue nil
            next if im && im.owner == klass
            klass.class_eval(<<~RUBY)
              def #{m}(*args, &block)
                __getobj__.send(:#{m}, *args, &block)
              end
            RUBY
          end
          klass.class_eval(<<~RUBY)
            def method_missing(name, *args, &block)
              __getobj__.send(name, *args, &block)
            end

            def respond_to_missing?(name, include_private = false)
              __getobj__.respond_to?(name, include_private) || super
            end
          RUBY
        end
      end

    end

    # Walk every module/class under `Mail` and make each un-shareable constant
    # into; leaf values (Regexp, Array, Hash, String, …) are frozen via
    # Ractor.make_shareable. Truly un-shareable values (e.g. Procs bound to the
    # main Ractor) are skipped — the worker would fall back to its own behavior.
    # This clears the `mail` gem's many Regexp module constants (e.g.
    # Mail::Utilities::TO_CRLF_REGEX), which would otherwise raise IsolationError
    # when read from a worker Ractor.
    def _make_mail_constants_shareable!
      root = ::Mail
      seen = {}
      walk = lambda do |mod|
        return if seen[mod.object_id]
        seen[mod.object_id] = true
        mod.constants(false).each do |cname|
          val = mod.const_get(cname)
          if val.is_a?(Module)
            walk.call(val)
          elsif !::Ractor.shareable?(val)
            begin
              ::Ractor.make_shareable(val)
            rescue StandardError
              nil
            end
          end
        rescue StandardError
          nil
        end
      end
      walk.call(root)
    rescue StandardError
      nil
    end
  end

  # --- ActionMailer::Base.mailer_name (raw class ivar on the mailer subclass) ---
  # `mailer_name` (aliased to `controller_path`) computes the mailer's view path
  # prefix from its class name, but reads the lazy `@mailer_name` class ivar —
  # unreadable from a worker Ractor ("can not get unshareable values from
  # instance variables of classes/modules from non-main Ractors"). The value
  # defaults to `name.underscore`, derivable from the (shareable) class name.
  #
  # Redefining `mailer_name`/`controller_path` directly does NOT help: every
  # internal caller captures the original method object through a stale
  # cross-Ractor inline cache, and `controller_path` is an alias bound to that
  # original method object. Instead we override the three internal callers
  # (each a small, stable method) via string-eval `def`, so the methods the
  # worker actually invokes derive the prefix from the shareable class `name`
  # directly — never touching `@mailer_name`.
  def self._install_actionmailer_mailer_name_patch
    return unless defined?(::ActionMailer::Base)
    return if @am_mailer_name_patched
    @am_mailer_name_patched = true

    # `ActionView::ViewPaths::ClassMethods#local_prefixes` (used by the mailer
    # view-path lookup) returns `[controller_path]`, and `controller_path` is an
    # alias for `ActionMailer::Base#mailer_name`. Override `local_prefixes`
    # itself (the method actually in the call stack) so mailer view prefixes are
    # derived from the shareable class `name` directly — never touching
    # `@mailer_name`.
    if defined?(::ActionView::ViewPaths::ClassMethods)
      amod = ::ActionView::ViewPaths::ClassMethods
      unless amod.private_instance_methods.include?(:rrs_original_local_prefixes)
        amod.alias_method :rrs_original_local_prefixes, :local_prefixes
      end
      amod.class_eval do
        def local_prefixes
          if defined?(::ActionMailer::Base) && self <= ::ActionMailer::Base
            [name.underscore]
          else
            rrs_original_local_prefixes
          end
        end
      end
    end

    # The three internal callers of `mailer_name`:
    #   * `collect_responses_from_templates` — template path lookup
    #   * `default_i18n_subject`             — I18n scope
    #   * `instrument_payload`               — ActiveSupport::Notifications payload
    # Re-implement each to use `self.class.name.underscore` (the same value
    # `mailer_name` would produce) without ever reading `@mailer_name`.
    #
    # Also make `PROTECTED_IVARS` (an unfrozen Array constant built at class-body
    # eval) shareable — otherwise a worker Ractor raises IsolationError reading
    # the non-shareable constant from `_protected_ivars`.
    unless ::Ractor.shareable?(::ActionMailer::Base::PROTECTED_IVARS)
      ::ActionMailer::Base.const_set(:PROTECTED_IVARS,
        ::Ractor.make_shareable(::ActionMailer::Base::PROTECTED_IVARS))
    end
    ::ActionMailer::Base.class_eval do
      def collect_responses_from_templates(headers)
        templates_path = headers[:template_path] ||
          (self.class.anonymous? ? "anonymous" : self.class.name.underscore)
        templates_name = headers[:template_name] || action_name

        each_template(Array(templates_path), templates_name).map do |template|
          format = template.format || self.formats.first
          {
            body: render(template: template, formats: [format]),
            content_type: Mime[format].to_s
          }
        end
      end

      def default_i18n_subject(interpolations = {})
        mailer_scope = (self.class.anonymous? ? "anonymous" : self.class.name.underscore).tr("/", ".")
        I18n.t(:subject, **interpolations, scope: [mailer_scope, action_name], default: action_name.humanize)
      end

      def instrument_payload(key)
        {
          mailer: self.class.anonymous? ? "anonymous" : self.class.name.underscore,
          key: key
        }
      end

      # `ActionMailer::Base#config` (a `class_attribute` on
      # `AbstractController::Base`) resolves to `nil` inside a worker Ractor
      # because the shim's frozen shareable fallback doesn't cover this mailer
      # instance receiver. `ActionView::Helpers::ControllerHelper#assign_controller`
      # then calls `controller.config.inheritable_copy` on nil and raises. Fall
      # back to an empty `OrderedOptions` (the class_attribute's own default) so
      # mailer view setup proceeds; the real config is only needed for delivery,
      # which routes through `Mail.delivery_method` (patched separately).
      def config
        super || ActiveSupport::OrderedOptions.new
      end
    end
  end
end
