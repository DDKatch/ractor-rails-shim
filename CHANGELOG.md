# Changelog

All notable changes to ractor-rails-shim are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-07-09

### Added — productionization (Phase 6)
- **Version detection infrastructure.** New `RactorRailsShim::Version` module
  with `Gem::Version`-based runtime checks (`ruby`, `rails`, `rails_segment`,
  `supported_ruby?`, `supported_rails?`, `satisfies?`). Replaces the string-
  prefix compare so pre-release and patch versions sort correctly.
  (`lib/ractor_rails_shim/version_check.rb`)
- **Version policy switch.** `RactorRailsShim.version_policy = :warn | :strict |
  :off`. The default `:warn` preserves backward compatibility; `:strict`
  raises `RactorRailsShim::UnsupportedVersionError` on untested Rails/Ruby;
  `:off` silences. (`patches.rb`)
- **Patch version registry.** Every `install_*` / `_install_*` method registers
  its tested Rails versions in `RactorRailsShim::PATCH_VERSIONS`. Use
  `RactorRailsShim.applicable_patches` to see which patches applied to the
  runtime (and which were skipped as untested). This is the "load different
  patches for different Rails versions" extension point — to add 7.x support,
  write version-specific variants and tag them in the registry.
  (`patches.rb`)
- **CI.** GitHub Actions workflow (`.github/workflows/ci.yml`): a fast unit
  job (no Rails) plus an integration job that builds the minimal Rails 8.1
  test app, makes it shareable, and dispatches `GET /up` in a worker Ractor —
  asserting HTTP 200. Also runs `ractor-rails-check` against the test app.
- **Unit specs** for the version infrastructure and the callable/lock
  replacement classes (`NoOpProc`, `Callable`, `CallableConst`,
  `RequestCallable`, `NoOpLock`, `NoOpLogDev`) — including cross-Ractor
  callability. (`spec/version_spec.rb`; 31 specs total, up from 8.)
- **CHANGELOG.md.**

### Changed
- `ractor-rails-shim.gemspec`: real metadata (`changelog_uri`,
  `bug_tracker_uri`, `rubygems_mfa_required`), canonical repo URL, CHANGELOG
  included in the gem package.
- `script/make_test_app.sh`: portable `sed` (was macOS-only `sed -i ''`,
  failed on Linux CI).
- Bumped version `0.1.0` → `0.2.0`.

### Fixed
- `.gitignore`: corrected `racker-rails-shim-*.gem` typo to
  `ractor-rails-shim-*.gem`.

## [0.1.0] - 2026-07-09

### Added
- Initial proof-of-concept. Reroutes Rails class-level instance variables
  (`Rails.application`, `Rails.cache`, `Rails.logger`, `mattr_accessor`,
  `class_attribute`, `Zeitwerk::Registry`, unshareable constants) through
  `IsolatedExecutionState` / `Ractor.make_shareable`.
- `make_app_shareable!` — replaces self-capturing Procs with callable objects,
  Mutex/Monitor with no-op locks, `Concurrent::Map` with frozen Hashes, then
  `Ractor.make_shareable(app)`. A worker Ractor dispatches `GET /up` → 200.
- `ractor-rails-check` CLI audit tool.
- Minimal unit specs (8) + an integration spec (self-skips without a test app).
- `NEXT_STEPS.md`, `VALIDATION.md`, `README.md`.
