# ractor-rails-shim

A monkey-patch shim that reroutes Rails' class-level instance variable accessors through `ActiveSupport::IsolatedExecutionState`, which is Ractor-safe. Lets a Rails app run in Ractor mode without forking Rails itself.

**Status:** proof-of-concept / stopgap. The goal is for Rails to do this upstream, at which point this gem becomes a no-op and can be removed.

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

## Install

Add to your Gemfile:

```ruby
gem "ractor-rails-shim", group: :production
```

Then install early in boot, before `Rails.application` is first accessed:

```ruby
# config/boot.rb
require "bundler/setup"
require "ractor-rails-shim"
Ractor::RailsShim.install
```

Or from a Rails console / runner for a quick check:

```ruby
require "ractor/rails_shim"
Ractor::RailsShim.install
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
  - require "ractor/rails_shim" and call Ractor::RailsShim.install before
    Rails.application is first accessed (early in config/boot.rb)
  - for shareable state (frozen config, route tables) use Ractor.make_shareable
    + a constant, NOT the shim — that shares one copy by reference
  - for per-Ractor mutable state use Ractor.store_if_absent(key) { default }
```

## What this fixes

- `Rails.application`, `Rails.app_class`, `Rails.cache`, `Rails.logger`, `Rails.env`, `Rails.backtrace_cleaner` — rerouted through `IsolatedExecutionState`.
- `Module.mattr_accessor` / `cattr_accessor` — the macro is rewritten so all ~150 call sites in Rails inherit the fix without individual edits. Pass `shareable: true` to opt an accessor into the shareable-by-reference path instead.

## What this does NOT fix

- **The boot-path lambda capture problem.** `Ractor.make_shareable(Rails.application)` still fails because of the routes-reloader lambda at `railties/lib/rails/application/finisher.rb:150` (it captures `self` = the app instance). Each worker Ractor would need to boot its own app instance via `Ractor.store_if_absent(:app) { Rails.application = App.new; ... }`. The shim enables this; it doesn't do it for you.
- **Gems.** Every gem your app depends on (Devise, Sidekiq, redis-rb, pg, etc.) has its own class ivars. The shim's `mattr_accessor` rewrite helps gems that use that macro, but gems using raw `@ivar ||= ...` need their own patches. The `--check` script surfaces these.
- **App code** holding mutable state in closures (`cache = {}; ->(env){ cache[...] }`). The shim can't see into closures; `--check` finds class ivars only.

## Limitations

- **Per-Ractor means N copies.** Each Ractor gets its own `Rails.application`, `Rails.cache`, etc. — same shape as forking N processes, but cheaper (no heap duplication). For large read-only state, use `Ractor.make_shareable` instead.
- **The mattr_accessor rewrite is broad.** It reroutes *all* `mattr_accessor`-defined accessors through `IsolatedExecutionState`, including ones that were legitimately class-global. This may change semantics for code that sets a value in main Ractor expecting worker Ractors to see it. Audit with `--check` and use `shareable: true` for accessors that should be shared.
- **Fragile across Rails versions.** This is a monkey-patch. Rails releases that touch `rails.rb` or `mattr_accessor` may break it. When upstream fixes it, delete the gem.

## License

MIT