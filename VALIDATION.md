# Validation against a real Rails app (Phase 1)

Results of validating `ractor-rails-shim` against a minimal Rails 8.1.3 app
(`rails new test_app --minimal`) on Ruby 4.0.6.

## Setup

1. `gem install rails --no-document` (Rails 8.1.3)
2. `rails new test_app --minimal --skip-git --skip-bundle`
3. Gemfile: `gem "ractor-rails-shim", path: ".../ractor-rails-shim"`
4. `config/boot.rb` — added before any `Rails.application` access:
   ```ruby
   require "bundler/setup"
   require "ractor_rails_shim"
   RactorRailsShim.install
   ```
5. `bundle install` and boot.

## Bugs found and fixed during validation

These were uncovered by running against a real Rails app (the unit specs use a
fake module that didn't exercise the real code paths).

1. **Wrong require path in `check.rb`.** `require "ractor/rails_shim/version"`
   should be `require_relative "version"`. The gem's namespace is
   `RactorRailsShim` (top-level), not `Ractor::RailsShim`, so the old path
   raised `LoadError` at boot. Fixed.

2. **`mattr_accessor` rewrite read the wrong storage.** Rails'
   `mattr_accessor`/`cattr_accessor` stores values in **class variables**
   (`@@sym`), but the shim's rewrite was reading **class instance variables**
   (`@sym`). The default value goes to `@@rescue_responses`, so the rerouted
   reader returned `nil` in the main Ractor and crashed the first initializer:
   ```
   ActionDispatch::ExceptionWrapper.rescue_responses.merge!(...)
   # undefined method `merge!' for nil   <- shim returned nil
   ```
   Class variables are *also* subject to `Ractor::IsolationError` from non-main
   Ractors (verified on Ruby 4.0.5: `class Foo; @@cv = {a:1}; end; Ractor.new{
   Foo.cv }` raises `can not access class variables from non-main Ractors`).
   Fix: the rewrite now reads/writes `@@sym` (via `class_variable_get/set`)
   in the main Ractor, and seeds worker IES slots from the captured `default:`
   value. Defaults are computed once in the main Ractor at define-time, the
   same way Rails does (including the block form `mattr_accessor(:x){ [...] }`).

3. **The audit scanner only inspected class instance variables (`@foo`), not
   class variables (`@@foo`).** This hid the entire category of blockers the
   shim actually targets. `Check` now scans both and tags each `Finding` with
   `kind: :ivar | :cvar`. The report breaks the count down and labels
   `@@foo` blockers as `mattr/cattr — shim targets`.

## Audit results (minimal Rails 8.1.3 app)

`RactorRailsShim::Check.scan` after boot:

| group | class-var (`@@foo`, shim fixes) | class-ivar (`@foo`, shim does NOT fix) | total |
|---|---:|---:|---:|
| Rails framework | 54 | 281 | 335 |
| app + gems (Bundler, I18n, TZInfo, Propshaft, Gem, URI…) | 32 | 117 | 149 |
| **total** | **86** | **398** | **484** |

### What the shim fixes automatically

- **`Rails.application`, `Rails.app_class`, `Rails.cache`, `Rails.logger`,
  `Rails.env`, `Rails.backtrace_cleaner`** — rerouted through IES by
  `install_rails_module`.
- **All `mattr_accessor`/`cattr_accessor` accessors** (86 class-var blockers in
  this app) — the macro rewrite routes them through IES. Verified working from
  a worker Ractor:
  - `ActionDispatch::ExceptionWrapper.rescue_responses` → Hash (16 entries, seeded from `default:`)
  - `ActiveRecord::SchemaDumper.ignore_tables` → Array (default `[]`)
  - `ActiveSupport.filter_parameters` → Array (seeded from default)
  - `ActionDispatch::Response.default_headers` → nil in worker (no `default:`; set by an initializer in main only — correct per-Ractor behavior)
  - `Propshaft.logger` → nil in worker (set in main only — correct)

### What the shim does NOT fix

The 398 class-ivar (`@foo`) blockers. These are raw `@ivar ||= [...]` /
`@ivar = Foo.new` patterns, not macro-defined. The largest categories in the
Rails framework:

| ivar | count | source / owner |
|---|---:|---|
| `@_dependencies` | 80 | `ActiveSupport::Concern` — accumulates included-module deps |
| `@_included_block` | 49 | `ActiveSupport::Concern` — the `included do … end` block |
| `@_eagerloaded_constants` | 18 | `ActiveSupport` eager-load tracking |
| `@initializers` | 12 | `Rails::Railtie` |
| `@runner` | 10 | `Rails::Railtie` |
| `@instance` | 7 | `Rails::Railtie` (singleton railtie instance) |
| `@deprecator` | 5 | per-framework `ActiveSupport::Deprecation` instances |
| `@rake_tasks` | 4 | `Rails::Railtie` |
| `@subscriber` | 4 | `ActiveSupport::Subscriber` subclasses |
| (78 more distinct ivars) | … | … |

These would each need either an upstream Rails fix (migrate to
`IsolatedExecutionState` or `Ractor.make_shareable`) or a targeted patch in the
shim. Most are set once at boot and read at runtime; many hold mutable
containers that genuinely need per-Ractor copies (Concern deps, initializer
collections) and some hold singletons (railtie `@instance`, `@deprecator`).

## Boot verification

- `bundle exec rails runner` — app initializes cleanly with the shim
  installed; `Rails.application`, `Rails.env`, `ActionDispatch::ExceptionWrapper.rescue_responses`
  all return expected values.
- `bundle exec puma -w 1 -t 1:1` (single worker, single thread) — Puma boots,
  `GET /up` returns HTTP 200, `GET /` returns HTTP 200. The shim does not break
  normal (single-Ractor) operation.

## Notes

- The gem auto-installs on require if Rails is already loaded (see
  `autoload_install!` in `ractor_rails_shim.rb`). To prove the blockers exist
  *without* the shim you must remove the gem from the Gemfile entirely —
  merely not calling `install` isn't enough, since `Bundler.require` triggers
  the auto-install. The unit spec (`spec/shim_spec.rb`, test 1) covers the
  "before shim" case with a fake module.
- Namespace is `RactorRailsShim` (top-level), NOT `Ractor::RailsShim`. The
  README's `Ractor::RailsShim.install` examples are stale and should be
  `RactorRailsShim.install`.