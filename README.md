# ractor-rails-shim

A monkey-patch shim that reroutes Rails' class-level instance variable accessors through `ActiveSupport::IsolatedExecutionState`, which is Ractor-safe. Lets a Rails app run in Ractor mode without forking Rails itself.

**Status:** proof-of-concept / stopgap. The goal is for Rails to do this upstream, at which point this gem becomes a no-op and can be removed.

**Current milestone:** on a minimal Rails 8.1 app (Ruby 4.0.5), a worker
Ractor dispatches `GET /up` → **HTTP 200** via `RactorRailsShim.make_app_shareable!`.
The shim builds a shareable fallback table for framework class config
(`class_attribute` / `mattr_accessor` values) and patches the raw class-ivar
accessors Rails reads per-request (`ExecutionWrapper.active_key`,
`Notifications.notifier`, `Inflections`, `PathRegistry`, `I18n`,
`AbstractController` lazy ivars, `Rack::Request`/`Utils`, `ExecutionContext`,
etc.). See `NEXT_STEPS.md` for the full blocker map.

## Why

Rails stores global state in class-level instance variables:

```ruby
class Rails
  class << self
    attr_accessor :app_class, :cache, :logger
    def application; @application ||= ...; end
  end
end
```

From a non-main Ractor, these reads/writes raise `Ractor::IsolationError`:

```
can not get unshareable values from instance variables of classes/modules
from non-main Ractors
```

This is the primary blocker preventing Rails from running in Ractor mode (see `kino/doc/rails-on-ractors.md` for the full diagnosis). The same pattern blocks Hanami, Padrino, Sinatra, and most Ruby web frameworks.

## How it works

The shim reroutes the accessor methods through `ActiveSupport::IsolatedExecutionState`, which is thread-local storage (`Thread.current[:key]`). Each Ractor has its own threads, so each Ractor gets its own slot automatically — verified on Ruby 4.0.5. Rails already uses this primitive for `ActiveRecord::ConnectionHandling.connection_handler` (for thread safety), so the pattern is proven in production.

Two storage paths, depending on the state's shape:

| path | primitive | sharing | mutability | use case |
|---|---|---|---|---|
| **per-Ractor** | `IsolatedExecutionState` / `Ractor.store_if_absent` | none (each Ractor own copy) | mutable | connection pools, per-Ractor config, logger |
| **shareable** | `Ractor.make_shareable` + constant | one copy, by reference | frozen (read-only) | route tables, frozen config, templates |

The shim uses the per-Ractor path by default. For shareable state, use `Ractor.make_shareable` directly — that's not this gem's job.

**Load order.** `install` may be called either before or after Rails is defined — the normal `config/boot.rb` path calls it before `require "rails"`. The `mattr_accessor` macro patch applies regardless; the Rails-module accessor patch (`Rails.application`, `Rails.env`, ...) defers via a `TracePoint(:class)` load hook that fires when `module Rails` opens.

## Install

Add to your Gemfile:

```ruby
gem "ractor-rails-shim", group: :production
```

Then install early in boot, before `Rails.application` is first accessed:

```ruby
# config/boot.rb
require "bundler/setup"
require "ractor_rails_shim"
RactorRailsShim.install
```

After Rails is fully booted (after `Rails.application.initialize!`) and **before
spawning worker Ractors**, call `prepare_for_ractors!` to make the remaining
unshareable constants (e.g. `Rails::Railtie::ABSTRACT_RAILTIES`, which loads
after `module Rails` opens) shareable:

```ruby
# config/environment.rb, or wherever you boot your app before spawning workers
Rails.application.initialize!
RactorRailsShim.prepare_for_ractors!
```

To share the whole app across worker Ractors (the `:ractor` mode path), call
`make_app_shareable!` — it replaces every self-capturing Proc in the app graph
with a callable object, every Mutex/Monitor with a no-op lock, and every
`Concurrent::Map` with a frozen Hash, then calls `Ractor.make_shareable`:

```ruby
Rails.application.initialize!
app = RactorRailsShim.make_app_shareable!(Rails.application)
# app is now frozen and Ractor.shareable? — pass it to worker Ractors:
worker = Ractor.new(app) { |a| a.call(env) }
```

**Note:** `make_app_shareable!` is production-only (the app becomes read-only).
It also **detaches the logger IO from the app graph**: `app.config.logger`
(the broadcast target holding the real `$stdout`/`$stderr` IO) is swapped for a
frozen no-op `BroadcastLogger` so `Ractor.make_shareable(app)` doesn't freeze
the process's real IOs, and the main ractor's `Rails.logger` (the per-Ractor
module accessor, not in the app graph) is re-pointed at a fresh live
`BroadcastLogger` → `$stderr` so main keeps logging. Worker ractors build their
own per-Ractor `Rails.logger` (a `BroadcastLogger` → `$stderr`). To fix
unshareable constants in your own app/gems, add them to the registry before
`prepare_for_ractors!`:

```ruby
RactorRailsShim.shareable_constants << "MyGem::MUTABLE_LIST"
RactorRailsShim.prepare_for_ractors!
```

Or from a Rails console / runner for a quick check:

```ruby
require "ractor_rails_shim"
RactorRailsShim.install
```

## Audit your app

```sh
bundle exec ractor-rails-check
# or scoped:
bundle exec ractor-rails-check --rails   # only Rails framework modules
bundle exec ractor-rails-check --app     # only app + gems
```

Reports class ivars holding unshareable values — the ones that would raise `Ractor::IsolationError` from a worker Ractor. Example:

```
ractor-rails-shim check: 23 class-ivar blocker(s) found

=== Rails framework (8) ===
  Rails@application = nil
  Rails@app_class = String
  Rails@cache = NilClass
  ...

=== app + gems (15) ===
  Devise@config = Devise::Config
  Sidekiq@options = Hash
  ...

hints:
  - require "ractor_rails_shim" and call RactorRailsShim.install before
    Rails.application is first accessed (early in config/boot.rb)
  - class-var (@@foo) blockers from mattr_accessor/cattr_accessor are rerouted
    by the shim automatically once installed
  - raw class-ivar (@foo) blockers are NOT fixed by the shim; patch the gem
    or use Ractor.make_shareable + a constant for shareable state
  - for per-Ractor mutable state use Ractor.store_if_absent(key) { default }
```

## What this fixes

- `Rails.application`, `Rails.app_class`, `Rails.cache`, `Rails.logger`, `Rails.env`, `Rails.backtrace_cleaner` — rerouted through `IsolatedExecutionState`.
- `Module.mattr_accessor` / `cattr_accessor` — the macro is rewritten so all ~150 call sites in Rails inherit the fix without individual edits. Pass `shareable: true` to opt an accessor into the shareable-by-reference path instead.
- `Class.class_attribute` (ActiveSupport) — the macro is rewritten so `executor`, `check`, and every other `class_attribute`-defined accessor routes through `IsolatedExecutionState` via string-eval'd methods (no captured binding). Without this, a worker Ractor calling `app.reloader.executor = ...` during boot raises "defined with an un-shareable Proc in a different Ractor".
- `Zeitwerk::Registry` class ivars (`@loaders`, `@mutex`, `@autoloads`, etc.) — routed through `IsolatedExecutionState` so a worker Ractor can create autoloaders (each Ractor gets its own registry).
- Unshareable constants (`Rails::Railtie::ABSTRACT_RAILTIES`, `ActiveSupport::EnvironmentInquirer::DEFAULT_ENVIRONMENTS`, etc.) — made shareable once at boot via `Ractor.make_shareable` + `const_set`. Add your own via `RactorRailsShim.shareable_constants << "MyGem::CONST"` then call `prepare_for_ractors!`.
- **Framework class config fallback** (`SHAREABLE_FALLBACK`) — at `make_app_shareable!` time the main ractor's live `class_attribute` / `mattr_accessor` values are captured, made shareable (callable-replacement for any Procs), and exposed as a read-only fallback. Worker readers return it when their per-Ractor IES slot is empty — this is what fixes `ActionController::Base.config` being nil in workers.
- **Raw class-ivar/cvar accessors Rails reads per-request** (the long tail beyond `mattr_accessor`) — patched individually: `ExecutionWrapper.active_key`, `ActiveSupport::Notifications.notifier`, `ActiveSupport.error_reporter`, `ActiveSupport::ExecutionContext` (after_change_callbacks / nestable), `ActiveSupport::Inflector::Inflections`, `ActionView::PathRegistry`, `ActionView::LookupContext` + `DetailsKey` (`view_context_class` built per-controller in main & shared via `VIEW_CONTEXT_REGISTRY`), `ActionView::Template::Handlers`, `AbstractController::Base` (`controller_path` / `action_methods` / `abstract` / `_prefixes` via per-Ractor Hash caches keyed by class), `AbstractController::UrlFor#action_methods` (sidesteps the unshareable `_routes` define_method-block), `ActionController::ParameterEncoding#action_encoding_template`, `Rack::Request` (`forwarded_priority` / `x_forwarded_proto_priority`), `Rack::Utils` (`default_query_parser` / multipart limits), `ActionDispatch::Request.parameter_parsers`, `I18n::Config` (`default_locale` / `locale`) + `I18n.fallbacks` + `I18n::Locale::Tag.implementation`.
- **`ActiveSupport::Callbacks#run_callbacks`** — made nil-safe so a worker Ractor whose `__callbacks` couldn't be shared (frozen, self-capturing-Proc callback chains) treats callbacks as empty. Correct for a read-only shared app where boot-time callbacks already ran in main.

## What this does NOT fix

- **Gems.** Every gem your app depends on (Devise, Sidekiq, redis-rb, pg, etc.) has its own class ivars. The shim's `mattr_accessor` rewrite helps gems that use that macro, but gems using raw `@ivar ||= ...` need their own patches. The `--check` script surfaces these.
- **App code** holding mutable state in closures (`cache = {}; ->(env){ cache[...] }`). The shim can't see into closures; `--check` finds class ivars only.
- **define_method-block methods.** A handful of Rails methods are defined via `define_method` with a block capturing the defining Ractor (e.g. `ActionDispatch::Routing::RouteSet`'s `_routes` singleton helper, `ActionView::Base.with_empty_template_cache`'s `compiled_method_container`). The shim works around these by building the affected classes (e.g. `view_context_class`) in the main Ractor and sharing them, or by reading the route set directly from the shared `Rails.application`. More complex apps may hit additional `define_method`-block call sites that need similar treatment.

## Limitations

- **Per-Ractor means N copies.** Each Ractor gets its own `Rails.application`, `Rails.cache`, etc. — same shape as forking N processes, but cheaper (no heap duplication). For large read-only state, use `Ractor.make_shareable` instead.
- **The mattr_accessor rewrite is broad.** It reroutes *all* `mattr_accessor`-defined accessors through `IsolatedExecutionState`, including ones that were legitimately class-global. This may change semantics for code that sets a value in main Ractor expecting worker Ractors to see it. Audit with `--check` and use `shareable: true` for accessors that should be shared.
- **Fragile across Rails versions.** This is a monkey-patch. Rails releases that touch `rails.rb` or `mattr_accessor` may break it. When upstream fixes it, delete the gem.

## License

MIT