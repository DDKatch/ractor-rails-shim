# Ractor-Rails-Shim — Architecture, Environment Model & Findings

> Reference/design document. For the task-oriented "what to do next", see
> `README.md`. This file captures *why* the shim is built the way it is,
> the dev/prod tradeoffs, and the conclusions reached while getting the
> `ractor-rails-shim-test-app` dummy app to serve under [kino](https://github.com/yaroslav/kino) `-m ractor`. On official Ruby 4.0.6 the upstream `kino` gem (0.1.3) works as-is — the per-ractor env-string cache fix now ships in 4.0.6, so the earlier DDKatch/kino fork is obsolete.

## 1. The core model: one frozen, shared app graph

kino's `:ractor` mode requires `Ractor.shareable?(app)` and hands the **same**
app object to every worker Ractor. To satisfy that, the shim builds the Rails
app and then deep-freezes it into a shareable graph via
`RactorRailsShim.make_app_shareable!(Rails.application)` (called from
`config_ractor.ru`). Every worker references that one immutable graph.

This is deliberate and is the shim's central optimization.

## 2. Why freeze at all? Ractors have no Copy-on-Write

Process-based servers (Puma cluster, Unicorn) boot Rails once in a master and
`fork` workers. The OS **Copy-on-Write (COW)** lets N forked workers share the
loaded app's physical RAM pages until one writes — so many workers with full
graphs cost almost no extra memory.

**Ractors are not processes and do not fork.** They are isolation boundaries
inside one process, with separate object heaps enforced by the Ruby runtime.
There is no OS-level COW between Ractor heaps. So N workers each holding their
own Rails graph pay **N× full memory and N× boot time**.

Hence the frozen **shared** graph: one graph, made `Ractor.shareable`,
referenced by all workers. No COW is needed because the graph is genuinely
shared. This is the Ractor-appropriate alternative to the process COW trick.

See `README.md` ("Kino status" / env analysis) and the dev/prod discussion
in chat history for the full COW explanation.

## 3. Ractor isolation restrictions the shim addresses

A non-main Ractor cannot:

| Restriction | Failure mode |
|---|---|
| Read non-shareable (mutable) objects across the boundary | `Ractor::IsolationError` |
| Read class/module ivars or constants holding mutable values (Regexps from `Regexp.union`, `Concurrent::Map`, Hashes w/ default procs, `Mutex`, captured `Proc`s) | `Ractor::IsolationError` |
| Write ivars on classes/modules | `Ractor::IsolationError` |
| Call a `Proc`/`block` defined in another Ractor | `defined with an un-shareable Proc in a different Ractor` |
| See main's top-level constants (only graph-reachable objects cross) | `NameError` for bare `Post` etc. |
| Autoload constants (Zeitwerk) | raises off-main |

## 4. How the shim solves each (env-agnostic)

All fixes are **Ractor-isolation fixes, not environment fixes** — they apply
identically to development and production. No per-`Rails.env` branching exists
in the shim.

- **Shareable constants** (`active_support.rb` `SHAREABLE_CONSTANTS` +
  `_install_json_encoding_patch`): deep-freeze `ActiveSupport::JSON::Encoding`
  constants (`HTML_ENTITIES_REGEX`, `ESCAPED_CHARS`, …) via
  `Ractor.make_shareable` + `const_set`; capture the JSON encoder class in
  `RactorRailsShim::JSON_ENCODER_CLASS` and build per-worker encoder instances
  via `IsolatedExecutionState`.
- **Un-shareable `Proc` → plain `def`** (`action_view.rb`
  `_install_with_empty_template_cache_patch`): the framework's
  `ActionView::Base.with_empty_template_cache` defines `compiled_method_container`
  via `define_method(:compiled_method_container) { subclass }` — a block/Proc
  captured in the main Ractor. Replaced with a block-free `def` returning the
  shared `RactorRailsShim::SHAREABLE_COMPILED_MODULE`.
- **Shared template container** (`SHAREABLE_COMPILED_MODULE`): all
  controllers/workers compile the `application` layout + Devise shared partials
  into one module, so they're visible everywhere. Dev's per-request recompile
  and prod's caching both still work on top of the shared container.
- **Class/module ivar reads** (Rails accessors, mattr/class_attribute,
  Inflections, I18n, ErrorReporter, Reloader, LogSubscriber, ExecutionContext…):
  routed through `IsolatedExecutionState` with a main-built shareable fallback.
  Main keeps its live value; workers get their own.
- **Locks / maps** (`Mutex`, `Concurrent::Map`, `CachingKeyGenerator` cache):
  replaced with `NoOpLock` / frozen-Hash / IES cache.
- **Controller `before_action`/`after_action` replay** (`make_shareable.rb` +
  `execution_wrapper.rb`): see §5b — captured by **intercepting
  `ActiveSupport::Callbacks.set_callback` at declaration time** (bypassing the
  corrupted eager-load `__callbacks` chain) and replayed per controller (walking
  ancestors for inheritance) inside the patched `run_callbacks` for worker
  Ractors.
- **Per-worker state that must be local** (app constants, built
  `view_context_class` registry, `Devise.mappings`, AR connection handler):
  captured in main, then **rebound / established lazily inside each worker's
  first request** (`WorkerApp#setup_once!`).

## 5. Dev vs Prod — what originally differed, and the latent prod bug

`config_ractor.ru` forces dev to behave like prod for the parts the frozen
graph requires:

| Concern | Dev default | Prod default | Forced in dev by `config_ractor.ru` |
|---|---|---|---|
| Eager loading | off | on | `eager_load = true` |
| Code reloading | on | off | `enable_reloading = false` |
| Template caching | off | on | `cache_template_loading = true` |
| Asset sweep cache | on | off | `sweep_cache = false` |
| Eager-load threads | many | 1 | `eager_load_threads = 1` |
| Eager-load-all loop (app + engine controllers) | n/a | n/a | runs in dev only |

Prod needs none of these (they're its defaults). They are boot *prerequisites*
for the frozen-graph model (autoloading is Ractor-unsafe, so the app must be
fully loaded before freeze), not env-specific "fixes."

**Latent production bug we uncovered:** the framework's `with_empty_template_cache`
`define_method(&block)` is an un-shareable Proc. In **dev** the view classes are
built lazily *after* the shim's patch installs, so the block-free `def` is used
and everything works. In **prod**, `DetailsKey.view_context_class` runs during
**eager load, before** `prepare_for_ractors!` installs the patch, caching the
block-based `compiled_method_container`. Every worker then calls it →
`defined with an un-shareable Proc in a different Ractor` on **every** page.
Dev-only testing had masked this entirely; the bug was real in production.

 **Fix:** install `_install_with_empty_template_cache_patch` **early** via
 `ActiveSupport.on_load(:action_view)` (in `core.rb#install`, before eager load),
 so prod uses the safe version. Env-agnostic, no branching.

 ## 5b. The eager-load callback-chain leak (the real blocker, and a false "200")

 The earlier "all routes 200 in both dev and prod under `kino -m ractor`" was a
 **false positive**. It only tested index/new actions, and the shim's worker
 `run_callbacks` swallowed the real error with a blanket `rescue`.

 **Root cause — a `class_attribute` callback-chain leak under eager load.**
 In **production (eager-load)**, every controller's `before_action`/`after_action`
 accumulate into a *single shared* `__callbacks[:process_action]` chain on
 `ApplicationController`. Concretely, `ApplicationController.__callbacks` ends up
 carrying Devise's `require_no_authentication`, `authenticate_scope!`, … **and**
 `PostsController`'s `set_post`. Reproducible with a bare
 `bin/rails runner` in production — i.e. **independent of the shim**, and the app
 is genuinely broken in eager-load mode. Almost certainly a Ruby 4.0.5 +
 Rails 8.1.3 + Devise 5.0.4 interaction (the copy-on-write guard inside Rails'
 `set_callback` mis-fires under Ruby 4.0.5, so the subclass write mutates the
 shared parent chain). In **dev (lazy-load)** the chain is correct.

 Consequences:
 - A request to `PostsController#show` invokes `require_no_authentication` (not a
   method on `PostsController`) → `NoMethodError`. The shim's worker
   `run_callbacks` had `rescue; end` around the replayed `send`, so it was
   **silently swallowed** and the action rendered with `@post` unset → a wrong
   but 200 response. That is why index/new "worked" and the bug stayed hidden.
 - `kino -m threaded` exposed it as a 500 (no isolation, the real `NoMethodError`
   surfaces).

 **Fix — capture each controller's OWN declared filters at declaration time.**
 `_install_callback_declaration_capture!` aliases
 `ActiveSupport::Callbacks.set_callback` and, during eager load, records per
 *declaring* controller class the symbolic `process_action` filters it declares
 (`kind`, `filter`, `only`/`except` read back from the `ActionFilter` in the
 `:if`/`:unless` options). This captures the **truth**, unaffected by the leak.
 `make_app_shareable!` freezes the table into
 `RactorRailsShim::SHAREABLE_DECLARED_CALLBACKS`; the patched worker
 `run_callbacks` replays it per controller (walking ancestors for inheritance,
 applying `only`/`except`, halting on a performed before-filter). Because we
 capture only what each class *declared*, the leaked foreign filters never run,
 and `respond_to?(filter, true)` guards each `send`.

 ## 6. Reload semantics & limitation

Because the graph is **frozen and shared**, it cannot be hot-reloaded.
`config_ractor.ru` disables `enable_reloading` in dev for exactly this reason.
Reloading would mutate the shared class graph, which is impossible once frozen.

To get reload with Ractors there are two real options (both require changing
kino, which today assumes one shareable app for a fixed pool):

- **(a) Frozen-graph + phased restart:** on each change/deploy, rebuild +
  `Ractor.make_shareable` a fresh graph and roll the worker pool onto it.
  Simple, keeps the memory-efficient shared graph, but per-change cost is a
  **full app reboot** (not fine-grained Zeitwerk reload) — poor dev ergonomics.
- **(b) Per-worker mutable graphs (moved in):** spawn each worker with its own
  graph via `Ractor.new(app) { |app| … }` (the `app` is *moved* into the
  worker, not shared). Then each worker can do real Zeitwerk reload, and rolling
  restarts still work for deploys. Gives true dev hot-reload, but pays N×
  memory/boot (no COW) and needs kino to support spawning workers with moved
  graphs.

You **cannot** reassign `Ractor.main` — a rolling design uses a **supervisor in
main** that swaps worker pools; workers are always non-main.

## 7. Current dev/prod mode status (validated vs target)

**Validated (all routes → 200, correct callback behavior, zero isolation errors):**
- `kino -m ractor` in **production** (`RAILS_ENV=production`): `/`, `/posts`,
  `/posts/1` (depends on `set_post` before_action), `/posts/new`,
  `/users/sign_in`, `/users/sign_up`, `/users/password/new` all return 200 with
  correct content. `/posts/1` proves the `set_post` replay works; the Devise
  routes prove `require_no_authentication`/`allow_params_authentication!`/etc.
  replay correctly. The only 500 (`/users/confirmation/new`) is a genuine missing
  route (Devise confirmable not enabled), not a shim bug. Shim unit specs: 31/31
  pass.
- `kino -m threaded` in **development** (mode-aware boot, `KINO_MODE=threaded`):
  same routes return 200 with code reloading ON (live reload). This is the
  intended dev path — lazy-load + no freeze means the eager-load callback leak
  never triggers and filters run normally.
- **`config_ractor.ru` is mode-aware**: `KINO_MODE` (or `RAILS_ENV`) selects
  `:ractor` (eager-load + freeze + shim) vs `:threaded` (plain Rails boot, lazy
  load, reloading on). Default: dev→threaded, prod→ractor. **Set `KINO_MODE` to
  match kino's `-m`** (kino consumes `-m` itself, so the boot file can't read
  it).

**Open / caveats:**
- `kino -m ractor` in **development** (i.e. forcing the frozen graph in a dev
  `RAILS_ENV`): kino's `resolve_mode` rejects the app as un-shareable when
  `KINO_MODE`/`RAILS_ENV` disagree with `-m`. A direct boot probe confirms the
  graph *is* `Ractor.shareable?` under the ractor code path, so this is a kino
  dev-boot artifact, not a shim regression. **Dev is meant for `:threaded`; use
  `:ractor` in production.** (If you need dev `:ractor`, set
  `KINO_MODE=ractor` to match `-m ractor`.)
- `:threaded` dev does **not** exercise Ractor isolation, so Ractor-only
  regressions won't surface there — keep a `:ractor` smoke test (CI or
  pre-deploy) in the loop.

## 8. Verification & commits

- Shim: `ractor-rails-shim` @ `60e978d` — early `with_empty_template_cache`
  install via `on_load`; shared `SHAREABLE_COMPILED_MODULE`; JSON const
  deep-freeze; callback `only`/`except` capture; removed debug probes.
- Test app: `ractor-rails-shim-test-app` @ `ad44763` — `config_ractor.ru` cleaned of debug
  probes.
- Both dev and prod verified 200 under `kino -m ractor` after `60e978d`.
- **Callback-leak fix (subsequent commit):** `make_shareable.rb` now intercepts
  `ActiveSupport::Callbacks.set_callback` (`_install_callback_declaration_capture!`)
  to capture each controller's own declared filters into
  `RactorRailsShim::SHAREABLE_DECLARED_CALLBACKS`; `execution_wrapper.rb` replays
  them per controller (ancestor walk, `only`/`except`, halt-on-perform) instead
  of reading the corrupted `__callbacks` chain; blanket `rescue` removed.
  `Devise::ALL/CONTROLLERS/ROUTES/STRATEGIES/URL_HELPERS/NO_INPUT` added to
  `SHAREABLE_CONSTANTS` (mutable module constants read by workers). `config_ractor.ru`
  made mode-aware (`KINO_MODE`/`RAILS_ENV`). Verified: prod `:ractor` and dev
  `:threaded` both serve all routes 200.
