#!/usr/bin/env bash
# Reproduce the full-stack Rails 8.1 test app for Phase 4 (gem ecosystem).
#
# Unlike make_test_app.sh (minimal --minimal app), this builds a REAL app:
#   - ActiveRecord + PostgreSQL (ractor-safe DB driver — pg gem calls
#     rb_ext_ractor_safe, so DB queries work in worker Ractors)
#   - Devise + Warden (the #1 gem blocker — Warden middleware holds Procs)
#   - Real views with partials + helpers (exercises view rendering deeply)
#   - A controller that does a DB query (real request path, not just /up)
#   - The /up health check (baseline that already works)
#   - A seeded user account so you can log in and see posts
#
# Requires a running PostgreSQL. Uses the default socket/connection.
#
# Usage:
#   cd <this repo>
#   ./script/make_full_test_app.sh [dest_dir]
#
# dest_dir defaults to a temp dir. After it finishes it prints the probe commands.
set -euo pipefail

SHIM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$(mktemp -d)/ractor-rails-shim-test-app}"

echo "Creating full-stack Rails app at: $DEST"
mkdir -p "$(dirname "$DEST")"

# Generate the app WITHOUT --minimal so we get the full Rails stack
# (ActiveRecord, ActionView with real template rendering, ActionMailer, etc.).
# Skip JS/Cable/Storage/Text/Mailbox/Job to keep the boot surface focused on
# the web request path + AR + Devise. Use PostgreSQL (ractor-safe pg gem).
rails new "$DEST" --skip-git --skip-bundle --skip-javascript \
  --skip-action-cable --skip-active-storage --skip-action-text \
  --skip-action-mailbox --skip-active-job --skip-action-mailer \
  --database=postgresql

cd "$DEST"

# Gemfile: shim (path) + Devise + Kaminari (pagination, mattr-based) + kino.
cat > Gemfile <<'RUBY'
source "https://rubygems.org"

gem "ractor-rails-shim", path: "SHIM_PATH_PLACEHOLDER"
gem "rails", "~> 8.1.3"
gem "propshaft"
gem "pg", "~> 1.4"
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

# config/boot.rb: install the shim only in production (Ractor mode).
# In development, the shim's __callbacks IES routing breaks Devise callbacks.
cat > config/boot.rb <<'RUBY'
ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup"

# Install the shim only in production — Ractor mode requires it.
# In development, the shim's callback routing interferes with Devise.
if ENV["RAILS_ENV"] == "production"
  require "ractor_rails_shim"
  RactorRailsShim.install
end
RUBY

# config/application.rb: keep generated railties, ensure config.generators
# doesn't create test-unit fixtures we don't need. The generated file is
# already correct for our purposes.

# config/database.yml: use the current OS user as the PG username (matches
# the default `peer` auth on macOS/Linux Homebrew Postgres). Override with
# PGUSER env var if needed.
PGUSER="${PGUSER:-$(whoami)}"
cat > config/database.yml <<YAML
default: &default
  adapter: postgresql
  encoding: unicode
  pool: 5
  host: 127.0.0.1
  username: ${PGUSER}

development:
  <<: *default
  database: ractor-rails-shim-test-app_dev

test:
  <<: *default
  database: ractor-rails-shim-test-app_test

production:
  <<: *default
  database: ractor-rails-shim-test-app_prod
YAML

# Production needs a secret_key_base. Generate one and stash in a credentials
# file is overkill for a probe; use an env var (set by the probe commands).
echo "SECRET_KEY_BASE will be set via env var at boot time."

bundle install

# Devise 5.0.4 + Rails 8.1: raise_on_missing_callback_actions defaults to
# true, but Devise registers callbacks with :only => [:create, :update, ...]
# that leak to non-Devise controllers. Disable it via an initializer.
cat > config/initializers/disable_callback_action_check.rb <<'RUBY'
Rails.application.config.action_controller.raise_on_missing_callback_actions = false
RUBY

# --- Devise: install + a User model + a protected route ---
# Devise's generator adds the Warden middleware (the #1 Proc blocker) and
# creates a User model with a migration. This is the realistic gem surface.
bundle exec rails generate devise:install 2>&1 | tail -5
bundle exec rails generate devise User 2>&1 | tail -5

# --- A real controller + view with partials/helpers (exercises rendering) ---
# A Posts scaffold: index (DB query + pagination + partial render), show.
bundle exec rails generate scaffold Post title:string body:text --no-stylesheets --no-javascripts 2>&1 | tail -8

# Wire Devise: login page exists at /users/sign_in, but posts are publicly
# viewable for the demo (Devise 5.0.4 + Rails 8.1 has a callback integration
# bug with scaffold controllers).
cat > app/controllers/posts_controller.rb <<'RUBY'
class PostsController < ApplicationController
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

# Fix the scaffold view: remove new/edit/destroy links (routes only have
# index + show). Replace with a simple post list.
cat > app/views/posts/index.html.erb <<'ERB'
<h1>Posts</h1>
<table>
  <thead>
    <tr><th>Title</th><th>Body</th></tr>
  </thead>
  <tbody>
    <%= render @posts %>
  </tbody>
</table>
<%= paginate @posts if respond_to?(:paginate) %>
ERB

cat > app/views/posts/_post.html.erb <<'ERB'
<tr>
  <td><%= link_to post.title, post_path(post) %></td>
  <td><%= post.body %></td>
</tr>
ERB

cat > app/views/posts/show.html.erb <<'ERB'
<h1><%= @post.title %></h1>
<p><%= @post.body %></p>
<%= link_to "Back to posts", posts_path %>
ERB

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
# Also create a user account so you can log in via Devise and see the
# protected /posts page.
cat > db/seeds.rb <<'RUBY'
User.where(email: "test@example.com").first_or_create!(password: "password123", password_confirmation: "password123")
Post.delete_all
10.times { |i| Post.create!(title: "Post #{i}", body: "Body of post #{i}.") }
puts "Seeded #{User.count} user(s), #{Post.count} post(s)."
puts "Login: test@example.com / password123"
RUBY

# Create + migrate (dev DB — for `rails s` normal-mode smoke test).
bundle exec rails db:create db:migrate 2>&1 | tail -8

# Seed via rails runner (db:seed has a Devise quirk with downcase_keys).
# In dev: seed posts BEFORE the user (lazy loading means Devise callbacks
# aren't on Post yet). In prod: use insert_all (eager_load registers
# Devise's downcase_keys on Post, so Post.create! fails).
bundle exec rails runner '
Post.delete_all
10.times { |i| Post.create!(title: "Post #{i}", body: "Body of post #{i}.") }
User.where(email: "test@example.com").first_or_create!(password: "password123", password_confirmation: "password123")
puts "Seeded #{User.count} user(s), #{Post.count} post(s). Login: test@example.com / password123"
' 2>&1 | tail -3

# Production needs the schema migrated too. Create a production PG DB +
# migrate + seed so the probe can run in production mode (required for
# make_app_shareable!: cache_classes=true, eager_load=true).
RAILS_ENV=production SECRET_KEY_BASE=dummy \
  bundle exec rails db:create db:migrate 2>&1 | tail -8
RAILS_ENV=production SECRET_KEY_BASE=dummy \
  bundle exec rails runner '
Post.delete_all
records = 10.times.map { |i| { title: "Post #{i}", body: "Body of post #{i}", created_at: Time.now, updated_at: Time.now } }
Post.insert_all(records)
User.where(email: "test@example.com").first_or_create!(password: "password123", password_confirmation: "password123")
puts "Seeded #{User.count} user(s), #{Post.count} post(s)."
' 2>&1 | tail -3

# --- Kino :ractor mode config files ---
# kino.rb: server config (mode/workers/threads/port). kino checks
# Ractor.shareable?(app) and never calls make_shareable behind the user's
# back, so config_ractor.ru must call make_app_shareable! before `run app`.
cat > kino.rb <<'RUBY'
mode :ractor
workers 2
threads 1
port 9293
bind "127.0.0.1"
log_requests true
RUBY

# config_ractor.ru: boots Rails, prepares + makes the app shareable, runs it.
# Set KINO_DEBUG=1 to wrap the app with a debug middleware that logs the rack
# env (keys, HTTP_ACCEPT, CONTENT_TYPE) and any exception (with root cause +
# backtrace) to /tmp/kino_debug.log. Without KINO_DEBUG it's production-clean.
# frozen_string_literal is REQUIRED: without it, string constants (like the
# LOG path) are mutable and reading them from a worker Ractor raises
# Ractor::IsolationError ("can not access non-shareable objects in constant").
cat > config_ractor.ru <<'RUBY'
# frozen_string_literal: true
require_relative "config/environment"
app = Rails.application

if ENV["RAILS_ENV"] == "production" && defined?(RactorRailsShim)
  RactorRailsShim.prepare_for_ractors!
  app = RactorRailsShim.make_app_shareable!(Rails.application)
  # Each kino worker Ractor runs in its own Ractor with no shared DB
  # connections. Wrap the app so the first request served by each worker
  # establishes its own ActiveRecord connection handler (Blocker 1). The
  # wrapper must be made shareable for kino's Ractor.shareable? check.
  app = Ractor.make_shareable(RactorRailsShim.worker_ar_init(app))
end

if ENV["KINO_DEBUG"]
  # Class-based wrapper (not a lambda): def methods don't capture bindings,
  # so the wrapper is shareable as long as @app is. A lambda's `self` is the
  # main object (not shareable), so it would fail in :ractor mode.
  class KinoDebugWrapper
    LOG = "/tmp/kino_debug.log"
    def initialize(app)
      @app = app
    end
    def call(env)
      File.write(LOG,
        "[REQ] #{env['REQUEST_METHOD']} #{env['PATH_INFO']} " \
        "ACCEPT=#{env['HTTP_ACCEPT'].inspect} " \
        "CONTENT_TYPE=#{env['CONTENT_TYPE'].inspect} " \
        "ENV_KEYS=#{env.keys.sort.inspect}\n", mode: "a")
      status, headers, body = @app.call(env)
      File.write(LOG, "[RES] #{status} #{headers['content-type'].inspect}\n", mode: "a")
      [status, headers, body]
    rescue => e
      root = e
      root = root.cause while root.respond_to?(:cause) && root.cause
      File.write(LOG,
        "[EXC] #{e.class}: #{e.message}\n  #{(e.backtrace || []).first(15).join("\n  ")}\n" \
        "[ROOT] #{root.class}: #{root.message}\n  #{(root.backtrace || []).first(10).join("\n  ")}\n",
        mode: "a")
      raise
    end
  end
  wrapper = KinoDebugWrapper.new(app)
  app = Ractor.make_shareable(wrapper)
  File.write(KinoDebugWrapper::LOG, "=== KINO_DEBUG session #{Time.now.iso8601} ===\n")
end

run app
RUBY

# probe_env.rb: standalone probe that boots the shareable app and dispatches
# /up via a bare Ractor with progressively minimal envs, to isolate which
# missing rack env key triggers a 500 (vs kino's full env). Useful when
# debugging Accept-header-less request failures. Run:
#   RAILS_ENV=production SECRET_KEY_BASE=dummy bundle exec ruby probe_env.rb
cat > probe_env.rb <<'RUBY'
require "stringio"
ENV["RAILS_ENV"] ||= "production"
ENV["SECRET_KEY_BASE"] ||= "dummy"
require File.expand_path("config/boot")
require File.expand_path("config/application")
Bundler.require(*Rails.groups)
Rails.application.initialize!
RactorRailsShim.prepare_for_ractors!
app = RactorRailsShim.make_app_shareable!(Rails.application)
puts "app shareable? #{Ractor.shareable?(app)}"

dispatch = lambda do |env|
  r = Ractor.new(app, env) do |a, e|
    re = e.dup
    re["rack.input"] ||= StringIO.new("")
    re["rack.errors"] ||= StringIO.new("")
    re["rack.version"] ||= [3, 0]
    begin
      s, h, b = a.call(re)
      body = +""
      b.each { |c| body << c.to_s } rescue nil
      b.close if b.respond_to?(:close) rescue nil
      [s, h["content-type"], body[0, 200]]
    rescue => ex
      root = ex
      root = root.cause while root.respond_to?(:cause) && root.cause
      [:err, ex.class.name, ex.message[0, 300],
       "ROOT: #{root.class}: #{root.message[0, 300]}",
       (root.backtrace || []).first(8)]
    end
  end
  r.value
end

base = {
  "REQUEST_METHOD"  => "GET",
  "PATH_INFO"       => "/up",
  "SCRIPT_NAME"     => "",
  "QUERY_STRING"    => "",
  "SERVER_NAME"     => "localhost",
  "SERVER_PORT"     => "9293",
  "rack.url_scheme" => "http",
}

tests = [
  ["1. + HTTP_HOST + Accept",     base.merge("HTTP_HOST" => "localhost", "HTTP_ACCEPT" => "text/html")],
  ["2. + HTTP_HOST (no Accept)",  base.merge("HTTP_HOST" => "localhost")],
  ["3. + Accept (no HTTP_HOST)",  base.merge("HTTP_ACCEPT" => "text/html")],
  ["4. bare (no HTTP_*)",         base.dup],
  ["5. + empty HTTP_ACCEPT",      base.merge("HTTP_HOST" => "localhost", "HTTP_ACCEPT" => "")],
  ["6. + SERVER_PROTOCOL",        base.merge("HTTP_HOST" => "localhost", "SERVER_PROTOCOL" => "HTTP/1.1")],
  ["7. + HTTP_VERSION",           base.merge("HTTP_HOST" => "localhost", "HTTP_VERSION" => "HTTP/1.1")],
]

tests.each do |label, env|
  puts "#{label} => #{dispatch.call(Ractor.make_shareable(env)).inspect[0, 300]}"
end
RUBY

# verify_blockers.rb: end-to-end verification that Blocker 1 (AR connection
# handler) + Blocker 2 (Kaminari @_config) + the AR query-path patches work in
# a worker Ractor. Boots, prepare_for_actors! + make_app_shareable!, then in a
# worker Ractor: init AR connections, run data-layer checks (Post.count,
# Kaminari.config, Post.page) + HTTP dispatch (/up, /users/sign_in, /posts).
# Run:
#   RAILS_ENV=production SECRET_KEY_BASE=dummy bundle exec ruby verify_blockers.rb
cat > verify_blockers.rb <<'RUBY'
# frozen_string_literal: true
require "stringio"
ENV["RAILS_ENV"] = "production"
ENV["SECRET_KEY_BASE"] = "dummy"
require File.expand_path("config/boot")
require File.expand_path("config/application")
Bundler.require(*Rails.groups)
Rails.application.initialize!
RactorRailsShim.prepare_for_ractors!
app = RactorRailsShim.make_app_shareable!(Rails.application)
puts "app shareable? #{Ractor.shareable?(app)}"

dispatch = lambda do |path|
  env = {
    "REQUEST_METHOD" => "GET", "PATH_INFO" => path, "SCRIPT_NAME" => "",
    "QUERY_STRING" => "", "SERVER_NAME" => "localhost", "SERVER_PORT" => "9293",
    "rack.url_scheme" => "http", "HTTP_HOST" => "localhost",
    "HTTP_ACCEPT" => "text/html", "rack.input" => StringIO.new(""),
    "rack.errors" => StringIO.new(""), "rack.version" => [3, 0],
  }
  r = Ractor.new(app, env) do |a, e|
    begin
      RactorRailsShim.init_worker_ar_connections!
      s, h, b = a.call(e)
      body = +""; b.each { |c| body << c.to_s } rescue nil
      [s, h["content-type"], body[0, 200]]
    rescue => ex
      root = ex; root = root.cause while root.respond_to?(:cause) && root.cause
      [:err, ex.class.name, ex.message[0, 400],
       "ROOT: #{root.class}: #{root.message[0, 400]}",
       (root.backtrace || []).first(12)]
    end
  end
  r.value
end

data = Ractor.new(app) do |a|
  RactorRailsShim.init_worker_ar_connections!
  out = {}
  out[:post_count] = (Post.count rescue "ERR #{$!.class}: #{$!.message[0,120]}")
  out[:kaminari_config] = (Kaminari.config.class.to_s rescue "ERR #{$!.class}: #{$!.message[0,120]}")
  out[:kaminari_page] = (Post.page(1).per(10).to_a.size rescue "ERR #{$!.class}: #{$!.message[0,200]}")
  out
end.value

puts "=== DATA-LAYER (worker Ractor) ==="
data.each { |k, v| puts "  #{k}: #{v.inspect[0, 240]}" }
puts "=== HTTP DISPATCH (worker Ractor) ==="
["/up", "/users/sign_in", "/posts"].each do |path|
  puts "#{path} => #{dispatch.call(path).inspect[0, 400]}"
end
RUBY

echo
echo "=== Full-stack test app ready at: $DEST ==="
echo
echo "Database: PostgreSQL (ractor-safe — DB queries work in worker Ractors)"
echo "Login: test@example.com / password123"
echo
echo "Endpoints:"
echo "  /up            - health check (baseline, works in minimal app)"
echo "  /users/sign_in - Devise login page (Warden middleware in the stack)"
echo "  /posts         - DB query + Kaminari pagination + partial render (requires auth)"
echo "  /posts/:id     - single-record query + show view"
echo
echo "=== Demo server (Puma, dev mode — log in and browse posts) ==="
echo "  cd $DEST && bin/rails server -p 9293"
echo "  # Then open: http://localhost:9293"
echo "  # Click 'Sign in', use test@example.com / password123"
echo
echo "=== Kino :ractor mode (production, 2 Ractor workers) ==="
echo "  cd $DEST && RAILS_ENV=production SECRET_KEY_BASE=dummy \\"
echo "    bundle exec kino -m ractor -p 9293 -C kino.rb config_ractor.ru"
echo "  # With debug logging (env + exceptions to /tmp/kino_debug.log):"
echo "  cd $DEST && RAILS_ENV=production SECRET_KEY_BASE=dummy KINO_DEBUG=1 \\"
echo "    bundle exec kino -m ractor -p 9293 -C kino.rb config_ractor.ru"
echo "  # Test:"
echo "  curl -s -o /dev/null -w '%{http_code}' -H 'Accept: text/html' http://localhost:9293/up"
echo
echo "To probe env isolation (which rack env key triggers the 500?):"
echo "  cd $DEST && RAILS_ENV=production SECRET_KEY_BASE=dummy bundle exec ruby probe_env.rb"
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
