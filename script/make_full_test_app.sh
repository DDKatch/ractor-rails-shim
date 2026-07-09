#!/usr/bin/env bash
# Reproduce the full-stack Rails 8.1 test app for Phase 4 (gem ecosystem).
#
# Unlike make_test_app.sh (minimal --minimal app), this builds a REAL app:
#   - ActiveRecord + sqlite (exercises the per-Ractor connection_handler path)
#   - Devise + Warden (the #1 gem blocker — Warden middleware holds Procs)
#   - Real views with partials + helpers (exercises view rendering deeply)
#   - A controller that does a DB query (real request path, not just /up)
#   - The /up health check (baseline that already works)
#
# Boots without external services (no Postgres/Redis/ES needed).
#
# Usage:
#   cd <this repo>
#   ./script/make_full_test_app.sh [dest_dir]
#
# dest_dir defaults to a temp dir. After it finishes it prints the probe commands.
set -euo pipefail

SHIM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$(mktemp -d)/full_test_app}"

echo "Creating full-stack Rails app at: $DEST"
mkdir -p "$(dirname "$DEST")"

# Generate the app WITHOUT --minimal so we get the full Rails stack
# (ActiveRecord, ActionView with real template rendering, ActionMailer, etc.).
# Skip JS/Cable/Storage/Text/Mailbox/Job to keep the boot surface focused on
# the web request path + AR + Devise.
rails new "$DEST" --skip-git --skip-bundle --skip-javascript \
  --skip-action-cable --skip-active-storage --skip-action-text \
  --skip-action-mailbox --skip-active-job --skip-action-mailer

cd "$DEST"

# Gemfile: shim (path) + Devise + Kaminari (pagination, mattr-based) + kino.
cat > Gemfile <<'RUBY'
source "https://rubygems.org"

gem "ractor-rails-shim", path: "SHIM_PATH_PLACEHOLDER"
gem "rails", "~> 8.1.3"
gem "propshaft"
gem "sqlite3", ">= 2.1"
gem "puma", ">= 5.0"
gem "kino"
gem "devise"
gem "kaminari"
gem "tzinfo-data", platforms: %i[ windows jruby ]

group :development, :test do
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"
end
RUBY
sed "s|SHIM_PATH_PLACEHOLDER|$SHIM_DIR|" Gemfile > Gemfile.tmp && mv Gemfile.tmp Gemfile

# config/boot.rb: install the shim before Rails.application is accessed.
cat > config/boot.rb <<'RUBY'
ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup"

require "ractor_rails_shim"
RactorRailsShim.install
RUBY

# config/application.rb: keep generated railties, ensure config.generators
# doesn't create test-unit fixtures we don't need. The generated file is
# already correct for our purposes.

# Production needs a secret_key_base. Generate one and stash in a credentials
# file is overkill for a probe; use an env var (set by the probe commands).
echo "SECRET_KEY_BASE will be set via env var at boot time."

bundle install

# --- Devise: install + a User model + a protected route ---
# Devise's generator adds the Warden middleware (the #1 Proc blocker) and
# creates a User model with a migration. This is the realistic gem surface.
bundle exec rails generate devise:install 2>&1 | tail -5
bundle exec rails generate devise User 2>&1 | tail -5

# --- A real controller + view with partials/helpers (exercises rendering) ---
# A Posts scaffold: index (DB query + pagination + partial render), show.
bundle exec rails generate scaffold Post title:string body:text --no-stylesheets --no-javascripts 2>&1 | tail -8

# Wire Devise: require authentication for posts.
cat > app/controllers/posts_controller.rb <<'RUBY'
class PostsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_post, only: %i[ show ]
  def index
    @posts = Post.page(params[:page] || 1).per(10)
  end
  def show
  end
  private
  def set_post
    @post = Post.find(params[:id])
  end
end
RUBY

# Routes: Devise + posts + the /up health check.
cat > config/routes.rb <<'RUBY'
Rails.application.routes.draw do
  devise_for :users
  resources :posts, only: %i[index show]
  get "up" => "rails/health#show", as: :rails_health_check
  root "posts#index"
end
RUBY

# Seed a few posts so the index page has data (exercises AR query + render).
cat > db/seeds.rb <<'RUBY'
10.times do |i|
  Post.find_or_create_by!(title: "Post #{i}", body: "Body of post #{i}.")
end
RUBY

# Migrate + seed (dev DB — the probe uses production, but we set up dev too
# so `rails s` works for a normal-boot smoke test).
bundle exec rails db:migrate db:seed 2>&1 | tail -5

# Production needs the schema migrated too. Create a production sqlite DB +
# migrate + seed so the probe can run in production mode (required for
# make_app_shareable!: cache_classes=true, eager_load=true).
RAILS_ENV=production SECRET_KEY_BASE=dummy \
  bundle exec rails db:migrate db:seed 2>&1 | tail -5

echo
echo "=== Full-stack test app ready at: $DEST ==="
echo
echo "Endpoints:"
echo "  /up            - health check (baseline, works in minimal app)"
echo "  /posts         - DB query + Kaminari pagination + partial render (requires auth)"
echo "  /posts/:id     - single-record query + show view"
echo "  /users/sign_in - Devise login page (Warden middleware in the stack)"
echo
echo "To boot under Puma single-worker (normal-mode smoke test):"
echo "  cd $DEST && bin/rails server -p 9293"
echo
echo "To run the shim audit (class-ivar blocker report):"
echo "  cd $DEST && bundle exec ruby -I$SHIM_DIR/lib -e '\\"
echo "    require \"ractor_rails_shim\"; require \"config/boot\"; require \"config/application\"; \\"
echo "    Bundler.require(*Rails.groups); Rails.application.initialize!; \\"
echo "    RactorRailsShim::Check.report(print: true)'"
echo
echo "To attempt make_app_shareable! + worker dispatch (GET /up → 200?):"
echo "  cd $DEST && RAILS_ENV=production SECRET_KEY_BASE=dummy bundle exec ruby -e '\\"
echo "    require File.expand_path(\"config/boot\"); \\"
echo "    require File.expand_path(\"config/application\"); \\"
echo "    Bundler.require(*Rails.groups); Rails.application.initialize!; \\"
echo "    app = RactorRailsShim.make_app_shareable!(Rails.application); \\"
echo "    env = Ractor.make_shareable({\"REQUEST_METHOD\"=>\"GET\",\"PATH_INFO\"=>\"/up\",\"SCRIPT_NAME\"=>\"\",\"QUERY_STRING\"=>\"\",\"SERVER_NAME\"=>\"localhost\",\"SERVER_PORT\"=>\"9293\",\"HTTP_HOST\"=>\"localhost\",\"rack.url_scheme\"=>\"http\"}); \\"
echo "    r = Ractor.new(app,env){|a,e| re=e.to_h.merge(\"rack.input\"=>StringIO.new(\"\"),\"rack.errors\"=>StringIO.new(\"\"),\"rack.version\"=>[3,0]); begin; s,h,b=a.call(re); [s,h[\"content-type\"],b.each.to_a.join[0,80]]; rescue=>ex; root=ex; root=root.cause while root.cause; [:err,ex.class.name,ex.message[0,150],\"ROOT: #{root.class.name}: #{root.message[0,150]}\"]; end }; \\"
echo "    puts r.value.inspect'"
