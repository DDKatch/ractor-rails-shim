# Gem Compatibility Matrix

Which gems work with `ractor-rails-shim` out of the box, which need patches,
and which are fundamentally incompatible with Ractor mode.

> **Methodology.** Each gem is classified by how it holds global state
> (class-level instance variables, class variables, constants, instance
> Mutexes, or captured Procs/closures) — the exact attributes the shim's
> audit (`ractor-rails-check`) inspects. Classifications marked **verified**
> were run against the gem; those marked **analyzed** are derived from the
> gem's source patterns (the storage class is known, but the gem wasn't
> loaded in a test app). Run `bundle exec ractor-rails-check --app` against
> your own app to get the authoritative list for your dependency set — this
> doc is a starting map, not a guarantee.

## Legend

| Status | Meaning |
|---|---|
| ✅ | Works out of the box. The shim reroutes its global storage, or it has no class-level mutable state. |
| ⚠️ | Needs a targeted patch. The gem uses raw `@ivar`/`@@cvar`/Mutex/Proc the shim doesn't auto-fix; patch it in the shim or upstream. |
| ❌ | Fundamentally incompatible. The gem's design (pervasive shared mutable state, process-identity assumptions) can't run in a frozen read-only shared app. Run it in a separate process. |

## Matrix

| Gem | Status | Storage class | Shim auto-fixes? | Notes |
|---|---|---|---|---|
| **rails** (8.1) | ✅ verified | mattr/cattr + class_attribute + constants + 7 Procs | yes (via `make_app_shareable!`) | The shim's whole purpose. Full-stack app (AR + Devise 5 + Propshaft + Kaminari + PG) dispatches every routable action in worker Ractors under `kino -m ractor`: `/up`, `/posts` (index/show/new/edit), Devise sign-in/sign-out (CSRF issue + validate), authenticated `POST /posts` → 302 (row persisted), `DELETE/PATCH /posts/:id`. |
| **propshaft** | ✅ analyzed | class_attribute + constants | yes | Static asset server; no per-request class state. |
| **puma** | ✅ analyzed | n/a (instance state) | n/a | Server, not in the app graph. Per-Ractor workers are the server's job (Kino/Puma), not the shim's. |
| **kino** | ✅ verified | — | n/a | The Ractor web server; runs `:ractor` mode against the shareable app. |
| **devise** | ✅ verified | mattr_accessor (mostly) + Warden closures | yes (with Warden patch) | Config is mattr → shim fixes. **Warden::Hooks** lazy class ivars (`@_on_request ||= []` etc.) patched: workers treat callback arrays as empty (correct for read-only shared app). Full Devise stack (sign-in, sign-out, CSRF issuance + validation, authenticated writes) dispatches in `kino -m ractor` worker Ractors → 200/302/303. |
| **warden** | ✅ verified (with patch) | class ivars + Procs | yes (shim patch) | `Warden::Hooks` has 6 lazy class ivars (`@_on_request`, `@_after_set_user`, `@_before_failure`, `@_after_failed_fetch`, `@_before_logout`, `@_on_request`) that lazily init at request time on the frozen middleware instance → IsolationError. Shim patches all 6 to return `[]` in workers (callbacks ran in main at boot). |
| **sidekiq** | ❌ analyzed | class ivars + Mutex + process-identity | no | Background job processor with pervasive shared mutable state, Redis connection pools, and a global scheduler loop. **Not a request-path dependency** — run it in a separate process. If your app merely *enqueues* jobs per-request, `Sidekiq::Client.push` reads `Sidekiq.redis_pool` (class ivar + Mutex) → would need a patch; prefer enqueuing via a shared Redis client built per-Ractor. |
| **sidekiq** (web dispatch only) | ⚠️ analyzed | `Sidekiq.options` class ivar | no | Only relevant if the app reads Sidekiq config during a request. Raw `@options`/`@redis_pool` class ivars raise IsolationError → patch the reader through IES (per-Ractor client) or avoid touching Sidekiq in the request path. |
| **redis** (redis-rb) | ⚠️ analyzed | instance Mutex + socket IO | n/a (instance) | `Redis::Client` holds a command `Mutex` and a socket — both **instance-level**, unshareable, but fine *if each Ractor builds its own client* (don't share one). `Redis.current` (deprecated class ivar) would block → don't use it; use a per-Ractor connection. |
| **pg** | ✅ analyzed | instance state + `PG::BasicTypeRegistry` | yes (via AR) | `PG::Connection` instances hold a socket (per-pool, per-Ractor via AR's `connection_handler` which Rails already IES-routes). Class-level registry state is minimal and shareable. |
| **mysql2** / **trilogy** | ✅ analyzed | instance state | yes (via AR) | Same shape as `pg`: connections are per-Ractor via AR's connection pool. |
| **activerecord** | ✅ verified | mattr + `connection_handler` (already IES) | yes | `connection_handler` is the one Rails global already migrated to `IsolatedExecutionState`. Per-Ractor connection pools work; each worker gets its own. (Caveat: large schemas / `default_scope` use class ivars — run `ractor-rails-check`.) |
| **viewcomponent** | ⚠️ analyzed | class_attribute + `@vc_*` ivars | partial | Config uses `class_attribute` (shim fixes). Component compile caches use raw `@_after_compile` / `@_sidecar` class ivars → may need the shareable-fallback treatment. `default_preview_paths` is class_attribute (fixed). |
| **kaminari** | ✅ analyzed | mattr_accessor | yes | Config (`default_per_page`, `max_pages`, `window`) is all mattr. |
| **pagy** | ✅ analyzed | `Pagy::DEFAULT` constant | yes (if frozen) | Config is a frozen Hash constant → shareable. No class ivars. |
| **ransack** | ⚠️ analyzed | mattr + raw ivars | partial | `Ransack.configure` uses mattr (fixed); `Ransack::Search` has raw `@_options` class ivars in some adapters. |
| **friendly_id** | ✅ analyzed | mattr_accessor | yes | Config is mattr. |
| **acts_as_taggable_on** | ✅ analyzed | mattr_accessor | yes | Config is mattr. |
| **faraday** | ⚠️ analyzed | class ivars + Mutex | no | `Faraday::MiddlewareRegistry` has `@middleware_mutex` (Mutex) + `@registered_middleware` (Hash). Needs NoOpLock replacement (like the app-graph locks) or a targeted IES patch. Connection *instances* are fine per-Ractor. |
| **httparty** | ✅ analyzed | class-level defaults (Hash) | yes (if frozen) | `HTTParty.default_options` is a class ivar holding a Hash → make shareable or seed per-Ractor. |
| **http.rb** | ✅ analyzed | instance state | yes | Stateless at the class level. |
| **jwt** | ⚠️ analyzed | class ivar `@config` | no | `JWT.configure` stores in `JWT::Configuration` singleton `@config`. Needs an IES-routed reader/writer patch. |
| **dry-configurable** / **dry-system** | ❌ analyzed | class-level `setting` macro + Mutex | no | `Dry::Configurable` stores settings in class ivars; `Dry::Container` uses a `Mutex`. Pervasive class state across the dry-rb stack. Needs either a shim patch per-class or upstream changes. |
| **aws-sdk** (aws-sdk-* ) | ❌ analyzed | `Aws.config` mutable Hash + global credentials | no | Heavy global mutable state (`Aws.config`, credential providers, region defaults). Designed for process-wide singletons. Run AWS calls in a separate process or build clients per-Ractor. |
| **google-cloud-* / fog** | ⚠️ analyzed | class-level config | partial | Similar to aws-sdk but lighter. `Fog.credentials` is a class ivar Hash. |
| **sentry-ruby** / **sentry-rails** | ⚠️ analyzed | `Sentry.configuration` singleton + Mutex | no | `Sentry::Hub` holds a Mutex and the config is a process singleton. The Rails integration subscribes to AS::Notifications (per-Ractor no-op in the shim's worker model). Needs a targeted patch for the config singleton, or run Sentry in a separate process. |
| **bugsnag** / **honeybadger** | ⚠️ analyzed | class-level config singleton | no | Same shape as Sentry: process-global config + a background thread for delivery. |
| **bootsnap** | ✅ analyzed | cache files + `Bootsnap::LoadPathCache` | n/a | Boot-time only; the cache is built before `make_app_shareable!` and isn't read at request time in production. |
| **lograge** | ✅ analyzed | class_attribute | yes | Config is class_attribute. |
| **bullet** (dev) | ⚠️ analyzed | class ivars + instance Mutex | no | Dev-only. `Bullet` holds `@enable`, `@warnings`, `@detected_associations` (class ivars) + an instance Mutex. Disable in production Ractor mode (it's a dev tool). |

## Patterns

### Gems that work (✅)
Two flavors: (a) **mattr/class_attribute-backed config** — the shim's macro
rewrites reroute these through IES automatically (Kaminari, FriendlyId,
Lograge). (b) **instance-state-only** gems where each Ractor builds its own
objects — no class-level state to share (http.rb, pg connections via AR's pool).

### Gems that need a patch (⚠️)
They use **raw `@ivar`/`@@cvar`** (not the mattr/class_attribute macros) or
hold **instance Mutexes / captured Procs** in shared objects. The fix is one
of:
- **IES-route the accessor** (same technique as the shim's
  `_install_active_support_error_reporter_patch`): define a string-eval'd
  reader/writer that reads from IES with a shareable fallback. Add it to
  `prepare_for_ractors!` or `make_app_shareable!`.
- **Callable-replacement** for Procs the gem holds in the app graph (like the
  shim's `Callable`/`NoOpProc` for `Rack::Files`/`ActionDispatch::SSL`).
- **NoOpLock** for Mutexes the gem holds (the shared app is read-only
  post-boot).

Open a PR adding the patch to `lib/ractor_rails_shim/patches/` (a new
per-concern file or an existing one) and an entry to `SHAREABLE_CONSTANTS`
for any unshareable constants the gem owns.

### Gems that are fundamentally incompatible (❌)
They're **process singletons by design**: background job processors
(Sidekiq), global SDK config (aws-sdk), or dry-rb's class-state-heavy
container system. These assume one mutable process-wide state graph — the
opposite of a frozen shared app. Run them in a **separate process** and talk
to them over IPC/Redis/an API. Don't try to load them into the shared app
graph.

## Auditing your own app

```sh
bundle exec ractor-rails-check --app   # app + gems (excludes Rails framework)
bundle exec ractor-rails-check        # everything
```

The report lists every class ivar / class var holding an unshareable value,
tagged by kind. Cross-reference each finding against this matrix:

- **`(mattr/cattr — shim targets)`** tag → already rerouted; no action.
- Untagged `@@foo` → likely a `mattr_accessor` the macro caught, or a raw
  class var needing a patch.
- Raw `@foo` → add a targeted patch (see "Gems that need a patch" above) or
  open an upstream issue.

For gems not in this matrix, the decision tree is:
1. Does it use `mattr_accessor`/`class_attribute`? → shim fixes it (✅).
2. Does it hold class ivars/vars directly? → needs a patch (⚠️).
3. Is it a process singleton with background threads + global mutable state?
   → incompatible, run in a separate process (❌).
4. Is it only used at boot time (not per-request)? → irrelevant in production
   (the shared app is frozen after boot).
