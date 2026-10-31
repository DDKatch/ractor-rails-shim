# frozen_string_literal: true

# Patch the telegram-bot gem (janko's Telegram::Bot) for worker Ractors.
#
#   1. `Telegram.bots` / `Telegram.bot` — lazily-memoized MODULE ivars holding
#      `Client` instances (which wrap an HTTPClient: mutable, own
#      threads/sockets). `lib/telegram/bot/config_methods.rb:31-45`. A worker
#      reading @bots raises IsolationError — and sharing one client across
#      Ractors would share one HTTPClient, which is wrong anyway.
#      Fix: per-Ractor clients via ::RactorRailsShim.storage. Main keeps its
#      memoized clients; each worker builds its own set from the (frozen,
#      shareable) `bots_config`. Secrets (tokens) live in `bots_config`, so
#      the config must be readable — see (2).
#
#   2. `Telegram.bots_config` — module ivar pulled from
#      Rails.application.credentials/secrets on first access. It is plain
#      String/Symbol data (HashWithIndifferentAccess), so it can be frozen
#      in place via the SHAREABLE_CLASS_IVARS registry: worker reads of the
#      frozen config are safe, and per-Ractor client construction (1) keys
#      off it.
#
#   3. `Bot::Async::ClassMethods#default_async_job` — lazily defines an
#      anonymous ApplicationJob subclass AND `const_set(:AsyncJob, klass)` on
#      the bot client class (`lib/telegram/bot/async.rb:57-65`). First
#      `async: true` send inside a worker → class-ivar write + const_set
#      from a non-main Ractor → IsolationError. Fix: main keeps the original
#      memo; workers build the job class into their per-Ractor storage
#      (no const_set — the constant is only a naming nicety).
#
#   4. `UpdatesPoller.@@instances` — class-variable Hash registry, only
#      exercised by dev polling / rake tasks. Routed through
#      ::RactorRailsShim.storage so even a stray worker access gets a
#      Ractor-local hash instead of raising on the shared class variable.

module RactorRailsShim
  SHAREABLE_CLASS_IVARS.concat([["Telegram", :@bots_config]])

  class << self
    def _install_telegram_bot_patch
      return if @telegram_bot_patched
      @telegram_bot_patched = true
      _register_patch :telegram_bot, "8.1"
      return unless defined?(::Telegram::Bot)

      _install_telegram_bot_clients
      _install_telegram_bot_async_job
      _install_telegram_bot_poller
    end

    private

    def _install_telegram_bot_clients
      ::Telegram::Bot::ConfigMethods.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def bots
          if ::Ractor.main?
            @bots ||= bots_config.each_with_object({}) do |(id, config), h|
              h[id] = ::Telegram::Bot::Client.wrap(config, id: id)
            end
          else
            key = :ractor_rails_shim_telegram_bots
            ::RactorRailsShim.storage[key] ||= bots_config.each_with_object({}) do |(id, config), h|
              h[id] = ::Telegram::Bot::Client.wrap(config, id: id)
            end
            ::RactorRailsShim.storage[key]
          end
        end

        def bot
          if ::Ractor.main?
            @bot ||= bots.fetch(:default) do
              raise 'Default bot is not configured.' \
                ' Add :default to bots_config' \
                ' or use telegram.bot/telegram.bots.default section in secrets.yml.'
            end
          else
            key = :ractor_rails_shim_telegram_bot
            ::::RactorRailsShim.storage[key] ||= bots.fetch(:default) do
              raise 'Default bot is not configured.' \
                ' Add :default to bots_config' \
                ' or use telegram.bot/telegram.bots.default section in secrets.yml.'
            end
            ::RactorRailsShim.storage[key]
          end
        end
      RUBY
    end

    def _install_telegram_bot_async_job
      return unless defined?(::Telegram::Bot::Async::ClassMethods)
      ::Telegram::Bot::Async::ClassMethods.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def default_async_job
          if ::Ractor.main?
            @default_async_job ||= begin
              begin
                ApplicationJob
              rescue ::NameError
                raise 'Define ApplicationJob class or setup #async= with custom job class'
              end
              klass = Class.new(::ApplicationJob) { include ::Telegram::Bot::Async::Job }
              klass.client_class = self
              const_set(:AsyncJob, klass)
              klass
            end
          else
            key = :"ractor_rails_shim_telegram_async_job_\#{object_id}"
            ::RactorRailsShim.storage[key] ||= begin
              klass = Class.new(::ApplicationJob) { include ::Telegram::Bot::Async::Job }
              klass.client_class = self
              klass
            end
            ::RactorRailsShim.storage[key]
          end
        end
      RUBY
    end

    def _install_telegram_bot_poller
      return unless defined?(::Telegram::Bot::UpdatesPoller)
      ::Telegram::Bot::UpdatesPoller.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def instances
          key = :ractor_rails_shim_telegram_poller_instances
          ::RactorRailsShim.storage[key] ||= {}
          ::RactorRailsShim.storage[key]
        end
      RUBY
    end
  end
end
