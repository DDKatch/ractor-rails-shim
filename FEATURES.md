# Rails Feature Support Matrix (worker Ractor mode)

Status legend:
- ✅ **supported** — verified working inside a `kino -m ractor` worker Ractor
- ⚠️ **unverified** — plausible but no worker-Ractor proof yet
- ❌ **unsupported** — known to break / not transported in a worker Ractor
- ➖ **n/a** — not exercised by this app

"App-used" = the test app (`ractor-rails-shim-test-app`) actually calls it.

## Controllers / routing
| Feature | Status | App-used | Notes |
|---|---|---|---|
| GET/POST/PATCH/DELETE dispatch | ✅ | yes | full CRUD over pg |
| `before_action` / `after_action` (symbolic) | ✅ | yes | captured + replayed per controller |
| `only:` / `except:` scoping + halt-on-perform | ✅ | yes | set_post/set_comment ordering fixed |
| `around_action` | ❌ | no | `:around` filters are recorded but never replayed (SymbolicTransport skips them by design) |
| `redirect_to @record` (full URL) | ✅ | yes | url_helpers worker fallback |
| `render html:` / ERB templates | ✅ | yes | with_empty_template_cache built in main |
| `render plain:` | ✅ | yes | used by StatsController |
| `render json:` | ✅ | yes | `_render_with_renderer_json` redefined as a shareable `def` (`_install_json_renderer_patch`); `:xml`/`:js` too |
| Named/Polymorphic URL helpers | ✅ | yes | HelperMethodBuilder worker fallback |
| CSRF token issue + validate | ✅ | yes | `verify_authenticity_token` replayed |

## Models / ActiveRecord
| Feature | Status | App-used | Notes |
|---|---|---|---|
| `before_save` / `after_create` / `before_validation` / `after_validation` / `after_commit` / `before_destroy` | ✅ | yes (`normalize_title`, `log_creation`, `enqueue_welcome_email`) | model lifecycle transport |
| `dependent: :destroy` cascade | ✅ | yes (Post→Comments) | DependentAssociationTransport |
| `belongs_to` / `has_many` | ✅ | yes | |
| lambda `scope` (`scope :recent`) | ✅ | yes | `_install_activerecord_scope_patch` re-evals the lambda source |
| `has_one_attached` (ActiveStorage) | ✅ | yes (`User#avatar`) | verified via `GET /attach_probe` → 200 (blob created, file uploaded, `identified=` persists) and `GET /attach_read_probe` → 200 (cross-worker read-back: attached, filename, byte_size, checksum). See TODO #4 for the full list of patched layers. **TODO #4** |
| `:counter_cache` | ✅ | no | per-worker memo cache in activerecord_reflection.rb |
| `after_create_commit` (DB-write trigger) | ✅ | yes | fires in worker after INSERT |

## Auth
| Feature | Status | App-used | Notes |
|---|---|---|---|
| Devise sign-in (Warden session write) | ✅ | yes | |
| Devise sign-out (reset_session) | ✅ | yes | |
| Devise registration | ✅ | yes | |
| `authenticate_user!` before_action | ✅ | yes | replayed in worker |

## Views / assets
| Feature | Status | App-used | Notes |
|---|---|---|---|
| ERB rendering + partials + layouts | ✅ | yes | |
| Propshaft asset serving (`/assets/*`) | ✅ | yes | |
| Kaminari pagination links | ✅ | yes | |
| `sanitize` / `simple_format` (Nokogiri) | ❌ | no | ractor-unsafe C ext — main-Ractor only in workers |

## Mail / jobs
| Feature | Status | App-used | Notes |
|---|---|---|---|
| `mail` gem inside a worker Ractor (parsing/encoding/building) | ✅ | yes | `_install_mail_patch`: cvars→IES, `Mail::Configuration.instance` per-worker, `Mail::Parsers::*Parser` + `Mail::Utilities` module ivars captured, `Mail::TestMailer.deliveries` per-Ractor, `Mail::PartsList`/`AttachmentsList` (`DelegateClass`) delegating methods redefined as shareable `def` |
| ActionMailer `deliver_now` from a worker Ractor | ✅ | yes (`UserMailer.welcome_email`) | full render + build + deliver works in a worker Ractor (verified via `GET /mail_probe` → 200 and `GET /mail_deliver_probe` → 200 with delivered_count, subject, body content). See TODO #3 for the full list of fixed layers. **TODO #3** |
| ActionMailer `deliver_later` (ActiveJob) | ❌ | yes (`WelcomeJob`) | enqueue from a worker Ractor; Sidekiq backend ❌; **TODO #5** |
| ActiveJob `perform_later` (enqueue from worker) | ❌ | yes (`WelcomeJob`) | enqueue from a worker Ractor; Sidekiq backend ❌; **TODO #5** |

## Misc
| Feature | Status | App-used | Notes |
|---|---|---|---|
| I18n (locale/fallback) | ✅ | yes | |
| Inflector | ✅ | yes | |
| pg driver | ✅ | yes | sqlite3/mysql2 ractor-unsafe |
| ActionCable | ➖ | no | |
| Fragment caching | ➖ | no | |

## Unsupported app-used features — implementation queue (TDD, one by one)
1. ✅ `render json:` — ActionController JSON renderer in worker Ractor (fixed: `_install_json_renderer_patch`)
2. ✅ `scope` lambda invocation in worker Ractor (already supported by `_install_activerecord_scope_patch`; verified with probe)
3. ✅ ActionMailer `deliver_now` in worker Ractor — **DONE** (verified: `GET /mail_probe` → 200)
   - Mail gem fully patched (`_install_mail_patch`): cvars→IES; `Mail::Configuration.instance`
     per-worker; `Mail::Parsers::*Parser` + `Mail::Utilities` module ivars captured into a
     shareable `RRS_MODULE_IVARS` const with string-eval `def` readers; `Mail::TestMailer.deliveries`
     per-Ractor; all `define_method` patches converted to string-eval `def`.
   - `Mail::PartsList` / `Mail::AttachmentsList` (`DelegateClass(Array)`) delegating
     methods (`[]`, `<<`, `each`, …), plus `__getobj__` / `__setobj__` / `initialize`,
     redefined as shareable string-eval `def`s delegating to `@delegate_dc_obj`.
   - ActionMailer::Base: the 3 internal `mailer_name` callers
     (`collect_responses_from_templates`, `default_i18n_subject`, `instrument_payload`)
     re-implemented via string-eval `def` to use `self.class.name.underscore` (never
     `@mailer_name`); `ActionView::ViewPaths::ClassMethods#local_prefixes` overridden for
     mailers; `ActionMailer::Base::PROTECTED_IVARS` made shareable; `config` falls back to
     an empty `OrderedOptions` when the `class_attribute` resolves nil in a worker.
   - SMTP delivery (`Mail::SMTP`) also viable in workers: `Mail.delivery_method` builds a
     fresh `Mail::SMTP` instance per call, and `Mail::SMTP::DEFAULTS` is made shareable by
     `_make_mail_constants_shareable!`.
4. ✅ ActiveStorage `has_one_attached` in worker Ractor — **DONE** (verified: `GET /attach_probe` → 200, `GET /attach_read_probe` → 200 cross-worker read-back)
   - `has_one_attached`/`has_many_attached` scope lambda built with a shareable `self` (`SHAREABLE_SCOPE_HOST`) so `User.reflections` is Ractor-shareable.
   - `ActiveStorage::Blob.build_after_unfurling` / `compute_checksum_in_chunks` redefined without `tap` blocks.
   - `ActiveStorage::Blob#service_name` falls back to `self.class.service&.name` when the `after_initialize` callback is skipped.
   - `ActiveStorage::Blob.type_for_attribute(:metadata)` / `attribute_types` / per-worker `_default_attributes` all force `Type::Serialized` with `IndifferentCoder(JSON)` for `:metadata`, so `read_attribute(:metadata)` returns a Hash (not a raw String) and store accessors (`identified=`, `analyzed=`, `composed=`) persist.
   - `generated_attribute_methods` modules captured in `SHAREABLE_GEN_ATTR_METHODS` at prepare time; worker Ractors read via per-Ractor IES instead of creating an empty Module (which would leave `name=`, `id=` undefined).
   - `ActiveRecord::Store#store_accessor` redefined as string-eval `def`s (shareable) instead of `define_method` blocks; `store_accessor_for` coder resolution block-free.
   - `ThroughReflection#source_reflection_name` respects `options[:source]` (was deriving from `name`, failing for `has_one :avatar_blob, through: :avatar_attachment, source: :blob`).
   - `ThroughReflection#check_validity!` uses per-worker cache instead of writing `@validated` on the frozen, shared reflection.
   - `full_table_name_prefix` / `full_table_name_suffix` reimplemented without un-shareable `module_parents.detect { }` blocks.
   - `attribute_names` aliased to `_rrs_orig_attribute_names` (was `super` with no superclass method); `define_attribute_methods` calls original in main (was no-op everywhere).
   - `SecureRandom::BASE36_ALPHABET` / `BASE58_ALPHABET` deep-frozen at `prepare_for_ractors!` time (module-body constants don't fire TracePoint(:constant)).
   - `ActiveStorage.table_name_prefix` / `table_name_suffix` readers redefined as shareable string-eval `def`s; `_seed_active_storage_prefix!` seeds the constants and resets `Blob`/`Attachment` `table_name` in main.
   - `Marcel::MimeType` / `Marcel::Magic` block-based methods redefined as string-eval `def`s; lookup tables frozen.
   - `ActiveStorage::Service::Registry#fetch` works (service instance is shareable via `class_attribute` fallback).
   - `Devise.mailer` `@@mailer_ref` cvar captured as shareable constant (`_install_devise_mailer_patch`); workers read the captured copy.
   - Callback `if:`/`unless:` Symbol conditions captured and checked via `condition_allows?` in SymbolicTransport (fixes Devise `after_update :send_email_changed_notification, if: :send_email_changed_notification?`).
   - Known workaround: `attach_probe` uses `blob.unfurl` + `blob.save!` + `ActiveStorage::Attachment.insert!` to bypass `has_one_attached`'s block-based `after_save` callback (lambda can't cross Ractor boundary) and the Attachment's `after_create_commit` callbacks (enqueue ActiveJobs via GlobalID, which reads an unshareable `@app` class ivar).
5. ❌ ActiveJob `perform_later` from a worker Ractor — enqueue from a worker Ractor is not yet supported; the ActiveJob queue adapter and GlobalID argument serialization read unshareable class ivars. **TODO #5**

## Known limitations
| Limitation | Status | Notes |
|---|---|---|
| `around_action` / `around_*` callbacks | ❌ (by design) | SymbolicTransport records `:around` filters but doesn't replay them (they must wrap the yield). |
| `sanitize` / `simple_format` (Nokogiri) | ❌ | ractor-unsafe C ext — main-Ractor only in workers. |
| ActiveJob `perform_later` / `deliver_later` | ❌ | TODO #5 — enqueue from a worker Ractor; queue adapter + GlobalID read unshareable class ivars. |
| `has_one_attached` block `after_save` callback | ⚠️ (workaround) | `has_one_attached` registers `after_save { ... }` (lambda), which can't cross Ractor boundary. Probe manually creates Blob + Attachment via `insert!`. |
| `ActiveStorage::Attachment` `after_create_commit` callbacks | ⚠️ (workaround) | Callbacks enqueue ActiveJobs via GlobalID, which reads an unshareable `@app` class ivar. Probe uses `insert!` to bypass callbacks. |
