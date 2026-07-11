# Ractor-Rails-Shim — Architecture, Environment Model & Findings

> Reference/design document. For the task-oriented "what to do next", see
> `NEXT_STEPS.md`. This file captures *why* the shim is built the way it is,
> the dev/prod tradeoffs, and the conclusions reached while getting the
> `full_test_app` dummy app to serve under `kino -m ractor`.

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

See `NEXT_STEPS.md` ("Kino status" / env analysis) and the dev/prod discussion
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
- **Callback `only`/`except`** (`make_shareable.rb`): captured from
  `ActionFilter`'s `@conditional_key` / `@actions` so Devise's
  `authenticate_scope!` doesn't wrongly fire on `new`/`create`.
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
so prod uses the safe version. Env-agnostic, no branching. After this, all
target routes return 200 in **both** dev and prod under `kino -m ractor`.

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

**Validated (all routes → 200, zero isolation errors):**
- `kino -m ractor` in **development** (with the dev-forcing in `config_ractor.ru`)
  and in **production** (`RAILS_ENV=production`): `/`, `/posts`, `/posts/new`,
  `/users/sign_in`, `/users/sign_up`, `/users/password/new`, and Tailwind CSS
  all return 200. The only 500 (`/users/confirmation/new`) is a genuine missing
  route (Devise confirmable not enabled), not a shim bug. Shim unit specs: 31/31
  pass.

**NOT yet working / open:**
- `kino -m threaded` currently **500s on every route** with
  `NoMethodError: undefined method 'include?' for nil` in
  `AbstractController::Base#action_method?` (a nil `@_action_methods` on the
  controller class). This is a *different* failure from the `:ractor` blockers
  we solved, and indicates kino's `:threaded` mode still executes the app inside
  a Ractor context where the controller action-method cache is unset, and/or the
  unconditional `make_app_shareable!` freeze in `config_ractor.ru` broke it.

**Conclusion / recommendation (design target, not yet realized):**
- The intended split is **`:threaded` for development (live reload),
  `:ractor` for production (memory density)**.
- But `:threaded` is **not** currently a working live-reload path. To realize
  it, `config_ractor.ru` must become **mode-aware**: skip `prepare_for_ractors!`
  / `make_app_shareable!` and keep `enable_reloading` when running `:threaded`
  (otherwise the app is still frozen and reload is impossible), and the
  `:threaded` `@_action_methods` nil bug must be root-caused and fixed.
- A separate caveat: `:threaded` dev does **not** exercise Ractor isolation, so
  Ractor-only regressions won't surface there — keep a `:ractor` smoke test
  (CI or pre-deploy) in the loop.

## 8. Verification & commits

- Shim: `ractor-rails-shim` @ `60e978d` — early `with_empty_template_cache`
  install via `on_load`; shared `SHAREABLE_COMPILED_MODULE`; JSON const
  deep-freeze; callback `only`/`except` capture; removed debug probes.
- Test app: `full_test_app` @ `ad44763` — `config_ractor.ru` cleaned of debug
  probes.
- Both dev and prod verified 200 under `kino -m ractor` after `60e978d`.
