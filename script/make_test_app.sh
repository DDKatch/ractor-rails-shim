#!/usr/bin/env bash
# Set up the REAL test app by cloning it from GitHub.
#
# The test app is a maintained repo (benchmarks, isolated engine, Dockerfile,
# CI, jruby Gemfile) — it cannot be reproduced by generating a Rails app from
# scratch. Cloning gives a runnable, benchmarkable app from the get go:
#
#   https://github.com/DDKatch/ractor-rails-shim-test-app
#
# Usage:
#   ./script/make_test_app.sh [dest_dir] [--no-update-shim]
#
# dest_dir defaults to a sibling of THIS repo:
#   <this repo>/../ractor-rails-shim-test-app
# All paths are computed relative to the script location, so the setup works
# on any machine layout.
#
# If dest_dir already holds a clone of the repo, the script updates it
# (fetch + ff-only pull; local commits and uncommitted changes are kept —
# a dirty tree only skips the pull, never the bundle steps). It never
# deletes or force-resets anything.
#
# The app depends on the shim through a GitHub git source; Gemfile.lock pins
# the revision (system-agnostic: CI and Dependabot resolve the same source,
# there is no path: reference to this machine). By default the script re-pins
# the shim to the latest origin/main, so the app runs the newest shim.
# Pass --no-update-shim to keep the locked revision (reproducible setup).
# The lockfile is repaired (consistent rev/version pin) as of the app
# repo's a5724d3, so --no-update-shim resolves cleanly; keep the default
# (re-pin) if you want the newest shim rather than the locked one.
#
# Requirements: git, network (clone + bundle), PostgreSQL for the DB steps
# (the script warns and continues if the DB is not reachable), `ab` for the
# benchmark harness.set -euo pipefail

REPO_URL="https://github.com/DDKatch/ractor-rails-shim-test-app.git"
SHIM_DIR="$(cd "$(dirname "$0")/.." && pwd)"

UPDATE_SHIM=1
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --no-update-shim) UPDATE_SHIM=0 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done
DEST="${POSITIONAL[0]:-$(dirname "$SHIM_DIR")/ractor-rails-shim-test-app}"

# --- clone or update -------------------------------------------------------
if [ -d "$DEST/.git" ]; then
  echo "== Test app already present at: $DEST"
  echo "   Updating from origin (ff-only; local work is kept)..."
  if git -C "$DEST" fetch --quiet origin 2>/dev/null; then
    git -C "$DEST" pull --ff-only --quiet origin \
      || echo "   WARN: pull skipped (uncommitted/diverging state) — current checkout kept." >&2
  else
    echo "   WARN: origin unreachable — using the current checkout." >&2
  fi
else
  echo "== Cloning test app into: $DEST"
  git clone --quiet "$REPO_URL" "$DEST"
fi
cd "$DEST"

# --- shim revision ----------------------------------------------------------
# `bundle lock --update <gem>` re-resolves version constraints but does NOT
# move a git-source gem's pinned revision — and the app repo's committed
# lockfile is internally inconsistent (it pins 0.6.1 @ a994c46, where
# version.rb was still 0.6.0), so fresh clones fail resolution with "that
# version can no longer be found in that source". `bundle update
# --conservative <gem>` force-re-resolves just this gem (moving the rev to
# the current branch head) without touching any other locked gem.
if [ "$UPDATE_SHIM" = 1 ]; then
  echo "== Re-pinning ractor-rails-shim to the latest origin/main..."
  bundle update --conservative ractor-rails-shim
else
  echo "== Keeping the locked shim revision (--no-update-shim)."
fi
SHIM_REV="$(awk '/^GIT$/{f=1} f && /^ *revision:/{print $2; exit}' Gemfile.lock)"
echo "   shim pinned at revision: ${SHIM_REV:-<none>}"

echo "== bundle install..."
bundle install --quiet

# --- database ---------------------------------------------------------------
# db:prepare is idempotent (create + migrate). Seeding gives a sign-in user
# (test@example.com / password123) for manual testing. The benchmark harness
# seeds its own user and points DATABASE_URL at the test DB itself.
echo "== rails db:prepare db:seed..."
if bundle exec rails db:prepare db:seed 2>&1 | tail -3; then
  :
else
  echo "   WARN: DB steps failed — is PostgreSQL running? Start it, then run:" >&2
  echo "     cd $DEST && bundle exec rails db:prepare db:seed" >&2
fi

# --- assets -------------------------------------------------------------------
# Production (kino :ractor / puma -e production) serves compiled assets:
# without this, every page that renders the layout 500s with
# "The asset 'tailwind.css' was not found in the load path". Same step the
# app's Dockerfile runs. Idempotent.
echo "== rails assets:precompile..."
SECRET_KEY_BASE_DUMMY=1 bundle exec rails assets:precompile \
  || echo "   WARN: asset precompile failed — pages that render the layout will 500." >&2

# --- how to use it -----------------------------------------------------------
echo
echo "=== Test app ready at: $DEST (shim rev ${SHIM_REV:-?}) ==="
echo
echo "kino :ractor (frozen shared graph, worker Ractors):"
echo "  cd $DEST"
echo "  RAILS_ENV=production SECRET_KEY_BASE=dummy KINO_MODE=ractor \\"
echo "    kino -m ractor -p 9293 -w5 -t1 -C kino.rb config_ractor.ru"
echo
echo "kino :threaded (dev, live reload):"
echo "  KINO_MODE=threaded kino -m threaded -p 9293 config_ractor.ru"
echo
echo "Puma clustered (macOS needs the fork-safety env):"
echo "  SERVER=puma OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES \\"
echo "    bundle exec puma config.ru -p 3000 -e production -w5"
echo
echo "Smoke checks:"
echo "  curl -s -o /dev/null -w \"%{http_code}\\n\" -H \"Accept: text/html\" http://localhost:9293/up"
echo "  curl -s -o /dev/null -w \"%{http_code}\\n\" -H \"Accept: text/html\" http://localhost:9293/posts"
echo "  curl -s -o /dev/null -w \"%{http_code}\\n\" -H \"Accept: text/html\" http://localhost:9293/users/sign_in"
echo
echo "Benchmarks (seeds its own user; needs PostgreSQL + ab):"
echo "  cd $DEST"
echo "  ruby bench/bench.rb                      # full matrix"
echo "  BENCH_DURATION=20 BENCH_CONCURRENCY=64 BENCH_RUNS=3 ruby bench/bench.rb"
echo
echo "Shim integration spec (run from the app's bundle):"
echo "  cd $DEST"
echo "  RAILS_SHIM_TEST_APP=$DEST RAILS_ENV=production SECRET_KEY_BASE=dummy \\"
echo "    bundle exec ruby -I$SHIM_DIR/lib -I$SHIM_DIR/spec \\"
echo "    -e 'require \"minitest/autorun\"; require \"$SHIM_DIR/spec/integration_spec.rb\"'"
echo
echo "Shim development on the local working copy (optional override):"
echo "  bundle config set --local local.ractor-rails-shim $SHIM_DIR && bundle install"
