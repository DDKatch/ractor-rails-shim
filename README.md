# ractor-rails-shim

A monkey-patch shim that reroutes Rails' class-level instance variable accessors
through `ActiveSupport::IsolatedExecutionState`, which is Ractor-safe. Lets a
Rails app run in Ractor mode without forking Rails itself.

**Status:** proof-of-concept / stopgap, currently **v0.5.1**. The goal is for
Rails to do this upstream, at which point this gem becomes a no-op and can be
removed (see [When to delete this gem](#when-to-delete-this-gem)).

**Verified as of 2026-10-25** on a full Rails 8.1.3.1 app (Devise 5, Propshaft,
Kaminari, PG, Solid Queue/Cache/Cable, Turbo, Action Mailbox/Text) under
**official Ruby 4.0.7**: worker Ractors serve every routable action — `GET
/up`, full ERB rendering, Devise sign-in/sign-out (CSRF issuance **and**
validation), authenticated writes (`POST /posts` → 302, row persisted), plus
Action Mailer, Active Storage, ActiveJob, Turbo Streams, and Solid Queue
enqueue from workers (143 of 144 audited Rails features pass; the one
unsupported feature is Nokogiri-backed `sanitize`/`simple_format` — see
[FEATURES.md](FEATURES.md)). Unit specs: **835 runs, 0 failures** (no Rails
dependency); an integration spec dispatches `GET /up` → 200 in a worker Ractor.

Under sustained load the app outperforms forked servers: on the 2026-10-25
benchmark (Ruby 4.0.7, YJIT on, 12 cores), **kino `:ractor` multiproc (4
processes × 5 ractors)** reaches **58,122 req/s** on the no-DB path — **2.73×
falcon forked** — at +13% memory, and single-process kino `:ractor` runs at
**255 MB** peak footprint, ~3.6× below the forked servers. Full tables:
[ractor-rails-shim-test-app/BENCHMARKS.md](https://github.com/DDKatch/ractor-rails-shim-test-app/blob/main/BENCHMARKS.md).

**No patched Ruby or kino required.** Official Ruby 4.0.6+ ships the
frozen-iseq call-cache fix (#22075) and the cross-ractor env-string fix, and
**4.0.7 additionally ships the YJIT/Ractor VM-lock fix**
([ruby#22224](https://bugs.ruby-lang.org/issues/22224) /
[ruby/ruby#18176](https://github.com/ruby/ruby/pull/18176)) — so no `YJIT off`
workaround either. Prefer 4.0.7.

## Documentation map

| Doc | Type | Read it for |
|---|---|---|
| [README.md](README.md) | how-to | install, run, audit — the two mode tracks |
| [ARCHITECTURE.md](ARCHITECTURE.md) | explanation | why the frozen shared graph exists, how each isolation wall is solved, file-by-file layout, POODR design notes |
| [FEATURES.md](FEATURES.md) | reference | Rails feature support matrix in worker Ractors |
| [COMPATIBILITY.md](COMPATIBILITY.md) | reference | gem-by-gem compatibility matrix and the decision tree |
| [VALIDATION.md](VALIDATION.md) | record | the Phase 1 validation run against a minimal app (historical) |
| [CHANGELOG.md](CHANGELOG.md) | reference | per-version changes |
| [UPSTREAM_ISSUE.md](UPSTREAM_ISSUE.md) | draft | the blocker map and the proposed incremental upstream merge plan |

## Requirements

- **Ruby >= 4.0.6, 4.0.7 preferred** — the shim relies on Ruby 4.0's Ractor
  semantics and `Ractor.make_shareable`, plus the frozen-iseq call-cache fix
  (#22075) and the cross-ractor env-string fix that both shipped in 4.0.6, and
  the YJIT/Ractor VM-lock fix that shipped in 4.0.7. It will not work (and
  refuses to install) on earlier Ruby versions.
- **Rails ~> 8.1** — tested against Rails 8.1.x class layouts. Other versions
  are not yet supported (see [Version compatibility](#version-compatibility)).

**Ractor-mode server:** the only Ruby web server that can run a Rails app in
Ractor mode is [kino](https://github.com/yaroslav/kino) (`kino -m ractor`).
On Ruby 4.0.6+ the **upstream `kino` gem works as-is** — the app pins
`~> 0.2.1`; no fork or patch is required. (Historically a DDKatch/kino fork
carried a per-ractor env-string cache fix; that fix landed in official Ruby
4.0.6, so the fork is obsolete.)

**Threaded servers (Puma/Falcon/Thin/Webrick):** set
`RactorRailsShim.thread_mode = true` (or `ENV["SERVER"]` to one of
`puma|falcon|thin|webrick|thread*`) and the shim installs a **minimal**
patch set — only the `class_attribute` isolation fix + nil-safe callback
replay. The per-Ractor IES-routing patches are skipped because IES is empty
on a thread server's request threads and would break the app; Rails' own
class globals are thread-safe and used as-is. Use this when you want the
callback-correctness fixes without running in Ractor mode.
**Never call `prepare_for_ractors!` or `make_app_shareable!` in thread mode** —
both are Ractor-mode-only (see the Install section's two tracks).

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

This is the primary blocker preventing Rails from running in Ractor mode (see
the [kino](https://github.com/yaroslav/kino) project's
`doc/rails-on-ractors.md` for the full diagnosis). The same pattern blocks
Hanami, Padrino, Sinatra, and most Ruby web frameworks. ARCHITECTURE.md
explains how the shim solves it, section by section.

## Install

Add to your Gemfile:

```ruby
gem "ractor-rails-shim", group: :production
```

**Pick exactly one track below** — the two modes install different patch sets
and use different lifecycle calls. Mixing them (e.g. calling
`prepare_for_ractors!` on a thread server) deep-freezes live Rails objects and
installs the full per-Ractor patch set in a mode that was never designed for
it; this breaks the app (frozen db configs, missing registries, nil
`action_methods`).

### Track A: Ractor mode (kino `-m ractor`)

Install early in boot, before `Rails.application` is first accessed:

```ruby
# config/boot.rb
require "bundler/setup"
require "ractor_rails_shim"
RactorRailsShim.install
```

After Rails is fully booted (after `Rails.application.initialize!`) and
**before spawning worker Ractors**, call `prepare_for_ractors!` to make the
remaining unshareable constants (e.g. `Rails::Railtie::ABSTRACT_RAILTIES`,
which loads after `module Rails` opens) shareable:

```ruby
# config/environment.rb, or wherever you boot your app before spawning workers
Rails.application.initialize!
RactorRailsShim.prepare_for_ractors!
```

**Do not set `RactorRailsShim.thread_mode = true` in this track.**

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
It also **detaches the logger IO from the app graph** so
`Ractor.make_shareable(app)` doesn't freeze the process's real IOs; the main
Ractor keeps logging, and each worker builds its own `Rails.logger`. To fix
unshareable constants in your own app/gems, add them to the registry before
`prepare_for_ractors!`:

```ruby
RactorRailsShim.shareable_constants << "MyGem::MUTABLE_LIST"
RactorRailsShim.prepare_for_ractors!
```

### Track B: Thread mode (Puma / Falcon / Thin / Webrick)

Set the mode **before** `install`, and install early in boot:

```ruby
# config/boot.rb
require "bundler/setup"
require "ractor_rails_shim"
RactorRailsShim.thread_mode = true   # or: ENV["SERVER"] = "falcon" before boot
RactorRailsShim.install
```

That is the **whole setup**. Thread mode installs a minimal patch set
(`class_attribute` isolation + nil-safe callback replay + callback capture) and
uses Rails' own thread-safe class globals as-is.

**Do NOT call `prepare_for_ractors!` or `make_app_shareable!` in thread mode.**
Both are Ractor-mode-only: they deep-freeze the app graph (db configurations,
constants, class ivars) and dispatch the full per-Ractor patch set, which a
threaded server cannot survive. (`prepare_for_ractors!` detects thread mode and
skips itself with a warning as of v0.4.1, but don't rely on that — keep it out
of your boot.)

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

Reports class ivars holding unshareable values — the ones that would raise
`Ractor::IsolationError` from a worker Ractor. Example:

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

- `Rails.application`, `Rails.app_class`, `Rails.cache`, `Rails.logger`,
  `Rails.env`, `Rails.backtrace_cleaner` — rerouted through
  `IsolatedExecutionState`.
- `Module.mattr_accessor` / `cattr_accessor` — the macro is rewritten so all
  ~150 call sites in Rails inherit the fix without individual edits. Pass
  `shareable: true` to opt an accessor into the shareable-by-reference path.
- `Class.class_attribute` (ActiveSupport) — the macro is rewritten so
  `executor`, `check`, and every other `class_attribute`-defined accessor
  routes through `IsolatedExecutionState` via string-eval'd methods (no
  captured binding).
- `Zeitwerk::Registry` class ivars — routed through `IsolatedExecutionState`
  so a worker Ractor can create autoloaders (each Ractor gets its own
  registry).
- Unshareable constants (`Rails::Railtie::ABSTRACT_RAILTIES`,
  `ActiveSupport::EnvironmentInquirer::DEFAULT_ENVIRONMENTS`, etc.) — made
  shareable once at boot via `Ractor.make_shareable` + `const_set`.
- **Framework class config fallback** (`SHAREABLE_FALLBACK`) — at
  `make_app_shareable!` time the main Ractor's live `class_attribute` /
  `mattr_accessor` values are captured and exposed as a read-only fallback;
  worker readers return it when their per-Ractor IES slot is empty. This is
  what fixes `ActionController::Base.config` being nil in workers.
- **Raw class-ivar/cvar accessors Rails reads per-request** (the long tail
  beyond `mattr_accessor`) — patched individually: `ExecutionWrapper.active_key`,
  `ActiveSupport::Notifications.notifier`, `ActiveSupport.error_reporter`,
  `ActiveSupport::ExecutionContext`, `ActiveSupport::Inflector::Inflections`,
  `ActionView::PathRegistry`, `ActionView::LookupContext` + `DetailsKey`,
  `ActionView::Template::Handlers`, `AbstractController::Base` caches,
  `Rack::Request` / `Rack::Utils`, `ActionDispatch::Request.parameter_parsers`,
  `I18n::Config` + fallbacks, and more. The full list with mechanisms is in
  [ARCHITECTURE.md](ARCHITECTURE.md) §4.
- **`ActiveSupport::Callbacks#run_callbacks`** — made nil-safe so a worker
  Ractor whose `__callbacks` couldn't be shared treats callbacks as empty,
  with captured callback descriptors replayed by a per-Ractor Registry
  (symbolic filters, `dependent: :destroy` cascades, autosave). ARCHITECTURE.md
  §5c has the transport design.

## What this does NOT fix

- **Gems.** Every gem your app depends on (Devise, Sidekiq, redis-rb, pg, etc.)
  has its own class ivars. The shim's `mattr_accessor` rewrite helps gems that
  use that macro, but gems using raw `@ivar ||= ...` need their own patches —
  either in the shim (many common ones already ship: Devise, Warden, Kaminari,
  mail, Turbo) or upstream. See [COMPATIBILITY.md](COMPATIBILITY.md).
- **App code** holding mutable state in closures
  (`cache = {}; ->(env){ cache[...] }`). The shim can't see into closures;
  `--check` finds class ivars only.
- **define_method-block methods.** A handful of Rails methods are defined via
  `define_method` with a block capturing the defining Ractor. The shim
  redefines the load-bearing ones as shareable `def`s or pre-builds the
  affected objects in the main Ractor; more complex apps may hit additional
  call sites.

## Limitations

- **Per-Ractor means N copies.** Each Ractor gets its own `Rails.application`,
  `Rails.cache`, etc. — same shape as forking N processes, but cheaper (no heap
  duplication). For large read-only state, use `Ractor.make_shareable`.
- **The mattr_accessor rewrite is broad.** It reroutes *all* `mattr_accessor`-
  defined accessors through `IsolatedExecutionState`, including ones that were
  legitimately class-global. This may change semantics for code that sets a
  value in main Ractor expecting worker Ractors to see it. Audit with
  `--check` and use `shareable: true` for accessors that should be shared.
- **Fragile across Rails versions.** This is a monkey-patch. Rails releases
  that touch `rails.rb` or `mattr_accessor` may break it. When upstream fixes
  it, delete the gem.

## Version compatibility

The shim targets specific Rails class layouts (8.1.x) and Ruby Ractor
semantics (4.0.x). At install it runs a real `Gem::Version`-based check (not a
string compare) and applies a configurable policy on mismatch:

```ruby
RactorRailsShim.version_policy = :strict  # raise on untested versions
RactorRailsShim.version_policy = :warn    # default: warn to $stderr, proceed
RactorRailsShim.version_policy = :off     # silent (experimentation)
```

Under `:strict` a mismatch raises `RactorRailsShim::UnsupportedVersionError`.
Each patch registers its tested Rails versions in
`RactorRailsShim::PATCH_VERSIONS`; query what applied to your runtime with:

```ruby
RactorRailsShim.applicable_patches
# => { applied: [:mattr_accessor, :rails_module, ...], skipped: [{name: ...}] }
```

Adding Rails 7.x support: the version-gated registry is the extension point —
write version-specific patch variants, tag them in `PATCH_VERSIONS`, and the
dispatcher applies only matching patches. (7.x is not yet supported; only 8.1
is tested today.)

## When to delete this gem

This shim is a **stopgap**. Delete it (remove from the Gemfile) when Rails
natively supports Ractor mode — i.e. when **all** of these land upstream:

1. Class-level instance variables / class variables backing `mattr_accessor`
   and `class_attribute` are migrated to `IsolatedExecutionState` (or
   equivalent Ractor-safe storage). Rails already does this for
   `ActiveRecord::ConnectionHandling.connection_handler`, proving the pattern.
2. The `Zeitwerk::Registry` class ivars route through Ractor-safe storage.
3. Unshareable constants (`EnvironmentInquirer::DEFAULT_ENVIRONMENTS`, etc.)
   are made shareable (deep-frozen) at boot.
4. The self-capturing Procs in the app graph are restructured to not capture
   `self` — e.g. the `Rack::Files` head lambda, `ActionDispatch::SSL` exclude
   proc, `CookieStore` same-site proc, the message-verifier secret generator,
   and the routes-reloader blocks. These block
   `Ractor.make_shareable(Rails.application)` upstream today (the shim
   replaces them with callable objects at boot).
5. Initializer blocks (`Rails::Initializable::Initializer#block`) are
   shareable (defined as methods, not closures) so per-Ractor boot works.

Until then, the shim is required. A simple canary: with the gem removed,
`Ractor.make_shareable(Rails.application)` fails (it raises on a Mutex or a
"Proc's self is not shareable"). When that call succeeds unshimmed, the gem is
obsolete. See [UPSTREAM_ISSUE.md](UPSTREAM_ISSUE.md) for the full blocker map
and the proposed incremental upstream merge plan.

## Publishing (maintainers)

The gemspec is publish-ready (metadata, MFA required, CHANGELOG packaged).
To release a new version:

```sh
# Bump lib/ractor_rails_shim/version.rb and add a CHANGELOG entry, then:
gem build ractor-rails-shim.gemspec
gem push ractor-rails-shim-<version>.gem
```

CI (`.github/workflows/ci.yml`) gates merges: unit specs (no Rails) + an
integration job that builds the minimal Rails 8.1 app and dispatches `GET /up`
in a worker Ractor. Don't publish from a red build.

## License

MIT
