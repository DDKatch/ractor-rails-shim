# Upstream gem-suite harness

Runs each patched gem's OWN test suite against ractor-rails-shim and reports
only shim-induced regressions.

## Method

The shim's patches are runtime monkey-patches, not source diffs. Applying a
generated diff to a gem clone would test a second representation of each
patch, not the gem the shim ships. So the harness loads the real shim at
runtime instead.

Each registered gem runs twice:

1. Baseline: the gem's suite, no shim. Failing test IDs form set A. These
   are the upstream's own failures on this Ruby build. They are expected
   and ignored.
2. With shim: the same suite with the shim loaded. Failing test IDs form
   set B.

Pass criterion: B minus A is empty. No test may fail with the shim that
passed in the baseline. A fully green suite is not required — upstream
suites often fail on Ractor-capable Rubies for reasons unrelated to the
shim.

This check verifies that the patches do not break the gem's ordinary,
non-Ractor behavior. It does not verify Ractor correctness. Ractor
correctness stays the job of `spec/` and the test-project smoke tests.

## Files

- `run.rb` — the matrix runner. Owns the gem registry (`GEMS`).
- `shim_prelude.rb` — `RUBYOPT` hook. Stdlib-only by design: `RUBYOPT` also
  runs inside the `bundle` CLI process before `Bundler.setup`. It loads the
  shim when the target gem's root constant appears.
- `gemfiles/<gem>.rb` — the bundle for each checkout. Contains the gem's
  own suite deps plus `activesupport` (required by the shim's loader) and
  the shim itself via `path:`.
- `checkouts/` — git clones at pinned refs. Not committed.

## How the shim gets activated in a suite

Two-phase activation, needed because some constants are autoloaded:

1. `shim_prelude.rb` hooks `Kernel#require`. When the gem's root constant
   is defined, it requires the shim and calls `RactorRailsShim.install`.
2. `run.rb` injects `test/zz_upstream_shim_dispatch_test.rb` into the
   checkout for the with-shim run only. The file sorts after every real
   test file, so it runs after all test classes load. It force-loads the
   `dispatch_when` constants (const_get resolves autoloads), then calls
   `Installer.dispatch_all_framework_patches`.

The dispatch file aborts if the shim is not loaded. A silent no-shim run
would otherwise produce a vacuous PASS.

## Usage

```
ruby upstream/run.rb                 # all registered gems
ruby upstream/run.rb --only i18n     # one gem
ruby upstream/run.rb --list          # show registry
```

Exit code is 0 on pass, 1 on fail. `WARN` means the run count changed but
no test regressed; investigate test collection.

## Adding a gem

Add one entry to `GEMS` in `run.rb` and one Gemfile in `gemfiles/`:

```ruby
"rack" => {
  repo: "https://github.com/rack/rack.git",
  ref: "3.2.8",                       # match a PATCH_VERSIONS segment
  suite: %w[bundle exec rake test TESTOPTS=-v],
  dispatch_when: "Rack",
},
```

Pin the ref to the version the shim actually runs against in production.
Use the project's `Gemfile.lock` as the source of truth. `dispatch_when`
takes full constant paths; the late dispatch file force-loads each one.

`dispatch_file` (optional) overrides the injected file's name — needed when
the suite collects test files with a glob other than `test/**/*_test.rb`
(e.g. tzinfo's `Dir["**/tc_*.rb"]`); the name must match that glob and sort
after the files that define the dispatch targets. `suite` may be a single
argv or a list of argvs when the gem needs several isolated processes (the
runner merges run counts and failing-test IDs across them).

## Findings from the first run (i18n 1.15.2)

The first pilot run found real bugs before going green. Kept here as
evidence the method works:

1. `available_locales_set` never invalidated — upstream clears the cached
   set in `available_locales=`, `load_path=`, and
   `clear_available_locales_set`. The shim's IES cache went stale, so
   availability checks rejected freshly stored locales. 1090 failures.
2. Main-Ractor readers diverged from upstream `||=` semantics. Readers
   returned an explicit `nil` where upstream falls back to the documented
   default (`:en`, `[]`). The suite's teardown sets these to `nil`, so the
   nil leaked into later tests. Fix: main runs upstream code verbatim;
   only worker Ractors use IES routing.
3. `%#{$3}` in an interpolated heredoc interpolated `$3` at patch-install
   time, not at call time. Generated code became `sprintf("%", value)`.
   Every sprintf-style placeholder was broken. Fix: escape as `%\#{$3}`.
4. `normalize_key`'s integer-key regex compiled without its backslashes.
   `\A`, `\d`, `\z` are unknown escapes in an interpolated heredoc. The
   generated regex `/A[-+]?([1-9]d*|0)z/` never matched, so numeric key
   segments came out as Symbols. Fix: build the regex outside the heredoc
   and interpolate `Regexp#inspect`.
5. `I18n.fallbacks` reader cached the class-level fallbacks. The upstream
   setter writes `@@fallbacks` and the fiber local, not the IES cache, so
   every later `I18n.fallbacks = X` read stale. Fix: main verbatim.
6. The backend `translations` patch lost upstream's default-block
   semantics: reading an unstored locale now returned `nil` instead of an
   empty hash.

## Findings from the expansion run (marcel 1.2.1)

7. `make_constants_shareable!` deep-froze Marcel's global lookup tables at
   dispatch, but upstream `Magic.add` / `Magic.remove` mutate those same
   tables — the public "register a custom MIME type" API raised
   FrozenError after boot. Caught by `test_add_and_remove_type` on the
   first marcel run. Fix: the same main-verbatim philosophy as i18n —
   the main Ractor keeps the live, mutable upstream tables and the routed
   wrappers call the upstream originals; worker Ractors read a deep-copied,
   frozen `MarcelPatch::SNAPSHOT` (built at dispatch, refreshed after every
   main-Ractor `add`/`remove`). Worker `add`/`remove` raise a descriptive
   error (the old code raised a bare FrozenError there anyway). Verified
   with a worker probe: custom types registered after dispatch are visible
   to workers, and removal propagates.

## Results

| gem | ref | runs | verdict |
|-----|-----|------|---------|
| i18n | v1.15.2 | 1888 | PASS (1 pre-existing failure, identical both sides) |
| rack | v3.2.8 | 1188 | PASS (clean both sides) |
| marcel | v1.2.1 | 447 | PASS after fix #7 |
| tzinfo | v2.0.6 | 1825 | PASS (66 pre-existing failures/skips, identical both sides) |

Not yet registered: concurrent-ruby, warden, kaminari (rspec suites — the
runner's parser and dispatch injection are minitest-only today), and the
Rails-embedded patches (rails/activerecord/etc. — their suites need a Rails
app harness).

## Known limitations

- Only patches whose target constants are defined get dispatched. The
  `@*_patched` flags in ~110 patch methods latch before their
  `defined?(...)` guards. A dispatch that runs before an autoloaded
  constant exists marks that patch applied forever. Production dispatches
  after boot, so this does not bite today — but it is the reason the
  harness dispatches late.
- minitest test order is random. A cross-test state leak may pass on one
  seed and fail on another. Re-run with the failing seed to confirm.
- `require_relative` bypasses the prelude's `Kernel#require` hook. Gems
  that load through `require_relative` need a different trigger constant.
