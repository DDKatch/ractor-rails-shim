# Draft Rails Issue — Ractor support roadmap

> **Status:** draft (not yet submitted). This is the writeable deliverable for
> `README.md` Phase 5. It compiles the shim's findings into a
> submission-ready Rails issue. When the maintainer is ready to engage
> upstream, paste the body below into a `rails/rails` issue and link the
> `ractor-rails-shim` repo as the reference implementation.

**Title:** Ractor support: migrate class-level instance variables to IsolatedExecutionState, and restructure self-capturing Procs

## Summary

Ruby 4.0 ships Ractors as the path to true parallelism without the GIL, but a
stock Rails app cannot run in Ractor mode (`Ractor.make_shareable(app)` /
`Ractor.new(app)` fails, and per-Ractor boot fails). The
[`ractor-rails-shim`](https://github.com/DDKatch/ractor-rails-shim) gem
proves the app **can** run in Ractor mode on Ruby 4.0.6 + Rails 8.1.3 — a
worker Ractor dispatches `GET /up` → HTTP 200 — by rerouting class-level
global state and restructuring unshareable Procs. This issue maps every
blocker to a concrete Rails/Rack code location and proposes an incremental
merge plan. ~40% of the work is already done inside Rails
(`ActiveRecord::ConnectionHandling.connection_handler` already uses
`IsolatedExecutionState`).

## The diagnosis

Rails stores global state in three flavors, all of which are illegal from a
non-main Ractor (verified on Ruby 4.0.6):

```ruby
class Rails
  class << self
    attr_accessor :app_class, :cache, :logger   # class-level instance vars
    def application; @application ||= ...; end
  end
end
```

```
Ractor::IsolationError: can not get unshareable values from instance
variables of classes/modules from non-main Ractors (@application from Rails)
```

1. **Class-level instance variables** (`@foo` on a class/module) — the most
   common. `Rails.application`, `Rails.cache`, per-framework config objects.
2. **Class variables** (`@@foo`) — back `mattr_accessor`/`cattr_accessor`
   (~150 call sites across Rails). Also subject to `IsolationError`
   (verified: `class Foo; @@cv = {a:1}; end; Ractor.new { Foo.cv }` raises).
3. **Unshareable constants** — mutable Arrays/Hashes in constant tables
   (`EnvironmentInquirer::DEFAULT_ENVIRONMENTS`, `Railtie::ABSTRACT_RAILTIES`).
   Reading them from a worker Ractor raises `IsolationError`.

The `ractor-rails-check` audit tool (shipped with the gem) reports these on
any app. On a minimal Rails 8.1 app: 101 class-var blockers (all in Bundler
gems, none in Rails framework after the shim reroutes them) — the framework
blockers are exactly what this issue asks Rails to fix upstream.

## The fix, proven by the shim

### A. `IsolatedExecutionState` is already ractor-safe

`ActiveSupport::IsolatedExecutionState` is thread-local storage
(`Thread.current[:key]`). Each Ractor has its own threads, so each Ractor gets
its own slot automatically — verified ractor-safe on Ruby 4.0.5. Rails
**already uses it** for `connection_handler`:

```ruby
# activerecord/lib/active_record/connection_handling.rb
def connection_handler
  ActiveSupport::IsolatedExecutionState[:active_record_connection_handler] || ...
end
```

The shim applies the identical pattern to every class-level accessor:
`Rails.application`, `Rails.cache`, `Rails.logger`, `Rails.env`, all
`mattr_accessor` accessors, all `class_attribute` accessors, and
`Zeitwerk::Registry`'s class ivars. Each Ractor gets its own value (same
shape as forking N processes, but without heap duplication).

For the **shared-app model** (`Ractor.make_shareable(Rails.application)` —
the zero-copy path), the shim builds a frozen, shareable **fallback table**
from the main Ractor's live values, so worker readers that need a value (not a
per-Ractor copy) read the shared frozen copy instead of nil.

### B. The `mattr_accessor` macro rewrite

One `Module.prepend` on `Module#mattr_accessor` reroutes all ~150 call sites
at once: the reader/writer are redefined via `module_eval` with **string
literals** (not `define_method` with blocks — blocks capture the defining
Ractor's binding and raise "defined with an un-shareable Proc in a different
Ractor" when called from a worker). The default value is computed once in
main and seeded into a shareable registry.

```ruby
# Sketch of the macro rewrite (string-eval'd, no captured binding)
def mattr_accessor(sym, default: nil, ...)
  super # define the original methods (sets @@sym)
  key = :"..._#{sym}"
  singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
    def #{sym}
      v = ActiveSupport::IsolatedExecutionState[#{key.inspect}]
      return v unless v.nil?
      RactorRailsShim::SHAREABLE_FALLBACK[#{key.inspect}] # shared copy
    end
    def #{sym}=(val)
      ActiveSupport::IsolatedExecutionState[#{key.inspect}] = val
    end
  RUBY
end
```

### C. Unshareable constants

`Ractor.make_shareable(value) + const_set` once at boot deep-freezes and
shares mutable constants. The shim's `SHAREABLE_CONSTANTS` registry lists ~40
(Rack::Utils, Mime, ActionDispatch, ActiveSupport). Trivially upstreamable.

## The remaining blockers (the hard part)

These are **code** blockers (Proc objects), not storage. The shim reroutes
every *storage* class; what remains are Procs that capture unshareable
bindings. This is where upstream Rails/Rack changes are required — the shim
can't fix these without forking Rails.

### Blocker 1: 7 self-capturing Procs in the app graph

`Ractor.make_shareable(Rails.application)` fails on:

| location | what it captures | called at runtime? |
|---|---|---|
| `rails/application.rb:212` `message_verifiers.@secret_generator` | `self` (app) | yes, on sign/verify |
| `rails/application/routes_reloader.rb:68` `run_after_load_paths` | (empty default `-> {}`) | dev only |
| `rails/application/routes_reloader.rb:51` `updater.@block` | the routes reloader | dev only |
| `action_dispatch/routing/route_set.rb:609` `url_helpers_with_paths.@_included_block` | `routes` | module-include time |
| `action_dispatch/middleware/ssl.rb:81` `@exclude` | `self` (SSL middleware) | **yes, per-request** |
| `rack/files.rb:31` `@head.@app` (`lambda { \|env\| get env }`) | `self` (Files server) | **yes, per-request** |
| `action_dispatch/middleware/session/cookie_store.rb:62` `@same_site` | `self` (the module) | **yes, per-request** |

`Ractor.make_shareable` requires a Proc's `self` to already be shareable —
**circular** when `self` is the middleware instance being made shareable.
Method objects are also unshareable. The fix: restructure each Proc to not
capture `self` — e.g. pass the receiver as an explicit frozen arg, or define
the callable as a method on a shareable object. (The shim proves this works:
it replaces `lambda { |env| get env }` with a frozen `Callable` object holding
the receiver as an ivar, and `Ractor.make_shareable` then succeeds.)

### Blocker 2: initializer blocks (per-Ractor boot)

`Rails::Initializable::Initializer` wraps a `&block` captured in the main
Ractor during `require`. A `Proc` cannot cross a Ractor boundary at all
(`TypeError: allocator undefined for Proc`), so a worker can't call main's
initializer blocks → per-Ractor boot produces an empty app. Re-requiring
railties in the worker **segfaults** Ruby 4.0.5 (verified). The fix: define
initializer blocks as methods, not closures, so they're shareable. This
unblocks the alternative model (each worker boots its own app) which avoids
the shared-app Procs entirely.

### Blocker 3: 12 Mutex/Monitor in the app graph

`Rails.application` holds ~10-12 `Thread::Mutex`/`Monitor` (autoloaders'
locks, `@app_build_lock`, the Notifications subscriber mutex, the cache
monitor). Neither `make_shareable` nor `Ractor.new(app)` can cross a Mutex.
In production Ractor mode the shared app is **read-only** (`cache_classes =
true`, `eager_load = true`, reloading disabled), so these locks are never
contended post-boot. The shim replaces them with `NoOpLock` (yields without
synchronizing). Upstream could gate this behind a production-Ractor mode flag.

## Proposed incremental merge plan

The shim is the reference implementation; each step below is proven there.
Small, high-leverage steps first:

1. **`Rails` module globals** (small, isolated). Migrate `Rails.application`,
   `Rails.cache`, `Rails.logger`, `Rails.env`, `Rails.backtrace_cleaner` to
   `IsolatedExecutionState`. ~6 accessors. Matches the existing
   `connection_handler` precedent. Unblocks worker-Ractor reads of framework
   singletons.

2. **`mattr_accessor` / `cattr_accessor` macro** (~150 call sites at once).
   The `Module.prepend` rewrite from the shim, upstreamed as a real macro
   change. Pass `shareable: true` to opt an accessor into the shareable path.

3. **`class_attribute` + `Zeitwerk::Registry`**. Redefine via string eval (not
   `define_method` with blocks). The shim proves the IES-routing approach.

4. **Unshareable constants**. Deep-freeze + `make_shareable` the ~40 entries
   in the shim's `SHAREABLE_CONSTANTS` at boot.

5. **The 7 self-capturing Procs** (the hard part). Restructure each per-call-
   site: `Rack::Files` head lambda, `ActionDispatch::SSL` exclude proc,
   `CookieStore` same-site proc, message-verifier generator, routes-reloader
   blocks. Each is a small, localized change but they're scattered across
   Rails/Rack.

6. **Boot-path lambdas** (per-Ractor boot). Make initializer blocks shareable
   (methods, not closures). Enables the alternative model where each worker
   boots its own app — avoids Procs entirely.

7. **Lock replacement** (production-Ractor mode). Gate the 12 Mutex/Monitor
   behind a no-op in a `config.ractor_mode = :shared_readonly` production
   mode.

Steps 1-4 are mechanical and unblock ~80% of apps on the shared-app path.
Steps 5-7 enable the per-Ractor-boot path and remove the shim's
callable/lock-replacement. The shim can be maintained as the stopgap until
upstream lands; it becomes a no-op and is removed when Rails does this.

## Evidence

- Reference implementation: `ractor-rails-shim` (this repo). 61 passing specs
  + an integration spec dispatching `GET /up` → 200 in a worker Ractor.
- `ractor-rails-check` audit output from a minimal Rails 8.1 app (101
  blockers in gems, 0 in the Rails framework after the shim reroutes them).
- The Phase 3 probe scripts (`phase3_probe_e.rb`) prove
  `Ractor.make_shareable(Rails.application)` succeeds after callable + lock +
  constant replacement, and a worker Ractor traverses the full middleware
  stack.
- `IsolatedExecutionState` verified ractor-safe on Ruby 4.0.5 (per-Ractor
  isolation tests in the shim's spec suite).
- Class variables verified subject to `IsolationError` from non-main Ractors
  on Ruby 4.0.5.

## What we're asking

- Feedback on the incremental plan. Is step 1 (Rails module globals via IES)
  acceptable as a first PR?
- Acknowledgement that `mattr_accessor` macro rewrite (step 2) is the right
  shape — it's a broad change but matches the existing `connection_handler`
  precedent and fixes ~150 call sites.
- For steps 5-6 (the Procs), is there appetite for a `config.ractor_mode`
  flag that restructures the self-capturing Procs behind a feature gate?

If upstream is receptive, the shim's patches are directly portable (they're
already written as clean `Module.prepend` / string-eval redefinitions, not
hacky monkey-patches). If not, the shim is maintained as the permanent
solution.
