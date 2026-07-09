# frozen_string_literal: true

# Phase 3 probe D: replace the 7 self-capturing Procs in the app graph with
# callable objects (regular objects with a `call` method holding references
# via ivars), then Ractor.make_shareable + worker dispatch.
#
# Key insight: make_shareable can freeze circular ivar graphs but NOT a Proc's
# captured binding (which includes self). So replace `lambda { |env| get env }`
# (captures self) with a callable object that holds `self` as an ivar —
# make_shareable freezes the object graph including the cycle.

APP_DIR = File.expand_path(ARGV[0] || Dir.pwd)
Dir.chdir(APP_DIR)
ENV["RAILS_ENV"] ||= "production"
ENV["SECRET_KEY_BASE"] ||= "dummy"
require File.join(APP_DIR, "config/boot")
require File.join(APP_DIR, "config/application")
Rails.application.initialize!
RactorRailsShim.prepare_for_ractors!

# --- Callable object replacements ---

# A generic callable that holds a target + method name, defined via string eval
# so no binding is captured. `call` sends the method to the target.
RactorRailsShim.module_eval <<-RUBY, __FILE__, __LINE__ + 1
  class Callable
    def initialize(target, method_name)
      @target = target
      @method_name = method_name
    end
    def call(*args)
      @target.__send__(@method_name, *args)
    end
  end
  class CallableNoArg
    def initialize(target, method_name)
      @target = target
      @method_name = method_name
    end
    def call
      @target.__send__(@method_name)
    end
  end
  # Holds a boolean (frozen) and returns it — replaces proc { !@redirect }
  class CallableConst
    def initialize(value); @value = value; end
    def call(*_); @value; end
  end
  # Replaces cookie_store @same_site: proc { |request| request.cookies_same_site_protection }
  # No captured state — just calls the method on the request arg.
  class SameSiteCallable
    def call(request); request.cookies_same_site_protection; end
  end
  # Replaces an ActiveSupport::Concern included block that captures `routes`.
  # The original block does:
  #   redefine_singleton_method(:_routes) { routes }
  #   define_method(:_routes) { @_routes || routes }
  # We hold routes via ivar and replicate via string eval (no captured binding).
  class IncludedBlockReplacer
    def initialize(mod, routes)
      @module = mod
      @routes = routes
    end
    def call(base)
      r = @routes
      base.singleton_class.define_method(:_routes) { r } # rubocop:disable nope
      base.define_method(:_routes) { @_routes || r }
    end
  end
RUBY

app = Rails.application

# --- Replace the 7 Procs ---

# 1. message_verifiers.@secret_generator: lambda { |salt, secret_key_base: ...|
#      key_generator(secret_key_base).generate_key(salt) }
#    Captures `self` (app). Replace with a callable that holds the app and
#    calls app.key_generator(secret_key_base).generate_key(salt).
mv = app.message_verifiers
if mv.instance_variable_defined?(:@secret_generator) && mv.instance_variable_get(:@secret_generator).is_a?(Proc)
  gen = mv.instance_variable_get(:@secret_generator)
  # The proc uses self.secret_key_base and self.key_generator — self is app.
  # Build a callable that replicates it.
  app_ref = app
  callable = RactorRailsShim::Callable.new(app_ref, :__shim_secret_generator)
  # Define the method on the app via string eval (no captured binding)
  app.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
    def __shim_secret_generator(salt, secret_key_base: nil)
      skb = secret_key_base || self.secret_key_base
      key_generator(skb).generate_key(salt)
    end
  RUBY
  mv.instance_variable_set(:@secret_generator, callable)
  puts "1. replaced message_verifiers.@secret_generator"
end

# 2. routes_reloader.@run_after_load_paths: -> { } (empty default in prod)
rr = app.routes_reloader
if rr.instance_variable_defined?(:@run_after_load_paths)
  rap = rr.instance_variable_get(:@run_after_load_paths)
  if rap.is_a?(Proc)
    # Simplest: a frozen no-op callable
    noop = Object.new
    def noop.call(*_); end
    noop.freeze
    rr.instance_variable_set(:@run_after_load_paths, noop)
    puts "2. replaced routes_reloader.@run_after_load_paths (no-op)"
  end
end

# 3. routes_reloader.@updater.@block: { reload! } capturing the reloader
if rr.instance_variable_defined?(:@updater)
  updater = rr.instance_variable_get(:@updater)
  if updater && updater.instance_variable_defined?(:@block)
    blk = updater.instance_variable_get(:@block)
    if blk.is_a?(Proc)
      # `reload!` is a method on the routes_reloader. The block captures self=rr.
      updater.instance_variable_set(:@block, RactorRailsShim::CallableNoArg.new(rr, :reload!))
      puts "3. replaced routes_reloader.@updater.@block"
    end
  end
end

# 4. route_set.@url_helpers_with_paths.@_included_block: an ActiveSupport::Concern
#    included block capturing `routes`. This is set by Concern#included.
#    The block does: redefine_singleton_method(:_routes) { routes };
#    define_method(:_routes) { @_routes || routes }.
#    This is module-include-time, not per-request. Replace with a callable
#    that holds routes and runs the same logic.
routes = app.routes
uwp = routes.instance_variable_get(:@url_helpers_with_paths)
if uwp.instance_variable_defined?(:@_included_block) && uwp.instance_variable_get(:@_included_block).is_a?(Proc)
  # Build a callable that mimics the included block. It needs `routes` (the
  # route set) to call redefine_singleton_method / define_method on the
  # including class. The block's self is uwp (the module).
  # We can't easily replicate Concern's included machinery, but this block
  # only runs when url_helpers is included into something — which happens
  # at boot, not per-request. Replace with a callable holding routes.
  inc = RactorRailsShim::IncludedBlockReplacer.new(uwp, routes)
  uwp.instance_variable_set(:@_included_block, inc)
  puts "4. replaced route_set.@url_helpers_with_paths.@_included_block"
end

# 5. ssl.@exclude: proc { !@redirect } capturing self (the SSL middleware).
#    Find the SSL middleware in the stack and replace @exclude with a callable
#    that holds the (frozen) redirect value.
def find_middleware(app_stack, klass_name, depth = 0, path = "app", seen = {})
  return nil if depth > 30
  return nil if seen[app_stack.object_id]
  seen[app_stack.object_id] = true
  if app_stack.class.name == klass_name
    return [app_stack, path]
  end
  app_stack.instance_variables.each do |iv|
    next if iv == :@app_build_lock
    begin; v = app_stack.instance_variable_get(iv); rescue; next; end
    if v && !v.is_a?(Mutex) && !v.is_a?(Monitor)
      r = find_middleware(v, klass_name, depth + 1, "#{path}.#{iv}", seen)
      return r if r
    end
  end
  nil
end

# Walk the middleware chain
mw = app.instance_variable_get(:@app)
ssl, ssl_path = find_middleware(mw, "ActionDispatch::SSL")
if ssl && ssl.instance_variable_defined?(:@exclude) && ssl.instance_variable_get(:@exclude).is_a?(Proc)
  redirect = ssl.instance_variable_get(:@redirect)
  # proc { !@redirect } -> callable returning !redirect
  ssl.instance_variable_set(:@exclude, RactorRailsShim::CallableConst.new(!redirect))
  puts "5. replaced ssl.@exclude (redirect=#{redirect.inspect})"
end

# 6. rack/files.@head.@app: lambda { |env| get env } capturing self (Files).
fs_server, fs_path = find_middleware(mw, "Rack::Files")
if fs_server.nil?
  # ActionDispatch::Static wraps Rack::Files in @file_server
  static, _ = find_middleware(mw, "ActionDispatch::Static")
  fs_server = static.instance_variable_get(:@file_server) if static
end
if fs_server && fs_server.instance_variable_defined?(:@head)
  head = fs_server.instance_variable_get(:@head)
  if head && head.instance_variable_defined?(:@app) && head.instance_variable_get(:@app).is_a?(Proc)
    head.instance_variable_set(:@app, RactorRailsShim::Callable.new(fs_server, :get))
    puts "6. replaced rack/files.@head.@app"
  end
end

# 7. cookie_store.@same_site: proc { |request| request.cookies_same_site_protection }
#    self is the module (shareable), BUT Ractor.make_shareable on the whole
#    graph re-attempts the proc and fails even if it's already shareable.
#    Replace with a callable object (not a Proc) that calls the method on the
#    request — no captured binding.
cs, _ = find_middleware(mw, "ActionDispatch::Session::CookieStore")
if cs && cs.instance_variable_defined?(:@same_site) && cs.instance_variable_get(:@same_site).is_a?(Proc)
  cs.instance_variable_set(:@same_site, RactorRailsShim::SameSiteCallable.new)
  puts "7. replaced cookie_store.@same_site with callable"
end

# --- Replace all Mutex/Monitor with NoOpLock ---
class RactorRailsShim::NoOpLock
  def synchronize; yield; end
  def mon_synchronize; yield; end
  def lock; self; end
  def unlock; self; end
  def locked?; false; end
  def mon_enter; end
  def mon_exit; end
  def mon_locked?; false; end
  def try_lock; true; end
  def new_cond; Struct.new(:wait, :signal, :broadcast).new(-> {}, -> {}, -> {}); end
end
seen = {}
stack = [[app, "app"]]
until stack.empty?
  o, _p = stack.pop
  next if o.nil? || seen[o.object_id]
  seen[o.object_id] = true
  next if o.is_a?(Mutex) || o.is_a?(Monitor)
  next if o.frozen? && Ractor.shareable?(o)
  o.instance_variables.each do |iv|
    begin; v = o.instance_variable_get(iv); rescue; next; end
    if v.is_a?(Mutex) || v.is_a?(Monitor)
      o.instance_variable_set(iv, RactorRailsShim::NoOpLock.new) rescue nil
    elsif v && !v.frozen?
      stack << [v, "#{_p}.#{iv}"]
    end
  end
end
puts "\n=== Replaced Mutex/Monitor ==="

# --- make_shareable ---
# First, list any remaining Procs in the graph (traverse ALL ivars, including
# in frozen/shareable objects — make_shareable does, so we must too)
seen3 = {}; remaining = []; stack = [[app, "app"]]
until stack.empty?
  o, p = stack.pop; next if o.nil? || seen3[o.object_id]; seen3[o.object_id] = true
  if o.is_a?(Proc); remaining << [p, o.source_location, Ractor.shareable?(o)]; next; end
  o.instance_variables.each do |iv|; begin; v = o.instance_variable_get(iv); rescue; next; end
    stack << [v, "#{p}.#{iv}"] if v
  end
end
puts "\n=== Remaining Procs before make_shareable (#{remaining.size}) ==="
remaining.each { |p, s, sh| puts "  #{p}  #{s.inspect} shareable=#{sh}" }

# Check the @same_site specifically
cs2, _ = find_middleware(mw, "ActionDispatch::Session::CookieStore")
if cs2
  ss2 = cs2.instance_variable_get(:@same_site)
  puts "cookie_store @same_site: class=#{ss2.class} shareable=#{Ractor.shareable?(ss2)}"
end

puts "\n=== Ractor.make_shareable(Rails.application) ==="
begin
  Ractor.make_shareable(app)
  puts "SUCCEEDED: shareable=#{Ractor.shareable?(app)}"
rescue => e
  puts "FAILED: #{e.class}: #{e.message[0,150]}"
  puts "  bt: #{e.backtrace.first(3).join("\n  ")}"
end

# --- Worker dispatch ---
puts "\n=== Worker dispatch ==="
env_tmpl = Ractor.make_shareable({
  "REQUEST_METHOD" => "GET", "PATH_INFO" => "/up", "SCRIPT_NAME" => "",
  "QUERY_STRING" => "", "SERVER_NAME" => "localhost", "SERVER_PORT" => "9293",
  "HTTP_HOST" => "localhost", "rack.url_scheme" => "http",
})
begin
  r = Ractor.new(app, env_tmpl) do |a, e|
    rack_env = e.to_h.merge(
      "rack.input" => StringIO.new(""), "rack.errors" => StringIO.new(""),
      "rack.version" => [3, 0],
    )
    s, h, b = a.call(rack_env)
    [s, h.keys, b.each.to_a.join.bytesize]
  rescue => ex
    [:err, ex.class.name, ex.message[0, 120]]
  end
  puts "result: #{r.value.inspect}"
rescue => e
  puts "spawn failed: #{e.class}: #{e.message[0,120]}"
end