# frozen_string_literal: true

# Phase 3 probe E: generic graph walk that replaces EVERY Proc in the app
# graph with a callable object (or no-op for boot-time procs), then
# Ractor.make_shareable + worker dispatch.
#
# After boot, boot-time procs (initializer blocks, railtie callbacks, routes
# reloader blocks, Concern included blocks) are never called again, so a
# no-op callable is safe. The 3 request-time procs (ssl @exclude, rack/files
# @head.@app, cookie @same_site) get semantic-preserving callables.
#
# Also replaces all Mutex/Monitor with NoOpLock (shared app is read-only).

APP_DIR = File.expand_path(ARGV[0] || Dir.pwd)
Dir.chdir(APP_DIR)
ENV["RAILS_ENV"] ||= "production"
ENV["SECRET_KEY_BASE"] ||= "dummy"
require File.join(APP_DIR, "config/boot")
require File.join(APP_DIR, "config/application")
Rails.application.initialize!
RactorRailsShim.prepare_for_ractors!

# --- Callable replacements (defined via string eval, no captured binding) ---
RactorRailsShim.module_eval <<-RUBY, __FILE__, __LINE__ + 1
  # No-op callable: replaces boot-time procs that are never called post-boot.
  class NoOpProc
    def call(*_); nil; end
  end
  # Holds a target + method name; forwards call. Replaces lambda { |env| get env }.
  class Callable
    def initialize(target, method_name)
      @target = target
      @method_name = method_name
    end
    def call(*args)
      @target.__send__(@method_name, *args)
    end
  end
  # Holds a frozen value; returns it. Replaces proc { !@redirect }.
  class CallableConst
    def initialize(value); @value = value; end
    def call(*_); @value; end
  end
  # Calls a method on the request arg. Replaces proc { |request| request.foo }.
  class RequestCallable
    def initialize(method_name); @method_name = method_name; end
    def call(request); request.__send__(@method_name); end
  end
  # No-op lock (Mutex/Monitor stand-in).
  class NoOpLock
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
RUBY

app = Rails.application
mw = app.instance_variable_get(:@app)

# --- Pre-compute lazy ivars that Rails would otherwise mutate at request
# time (env_config, app_env_config, routes helpers). Once the app is frozen
# (shareable), the `@x ||= {}` lazy-init writes fail with FrozenError, AND
# pre-computing now exposes the procs they hold so the replacement pass
# catches them. Force them before the proc-replacement walk. ---
app.env_config
app.app_env_config rescue nil
app.routes.url_helpers rescue nil
app.routes.named_routes rescue nil
app.routes.helpers rescue nil

# --- Identify the 3 request-time procs by location for semantic replacement ---
# ssl @exclude (ssl.rb:81): proc { !@redirect } -> CallableConst(!redirect)
# rack/files @head.@app (files.rb:31): lambda { |env| get env } -> Callable(files, :get)
# cookie @same_site (cookie_store.rb:62): proc { |req| req.cookies_same_site_protection } -> RequestCallable(:cookies_same_site_protection)

SSL_LOC = "/active_dispatch/middleware/ssl.rb"
FILES_LOC = "/rack/files.rb"
COOKIE_LOC = "/session/cookie_store.rb"

# Build a map of object_id -> [parent, ivar, proc] for all Procs, so we can
# replace them after identifying the semantic ones.
seen = {}
procs = []
stack = [[app, "app", nil, nil]]
until stack.empty?
  o, path, parent, ivar = stack.pop
  next if o.nil? || seen[o.object_id]
  seen[o.object_id] = true
  if o.is_a?(Proc)
    procs << [o, path, parent, ivar]
    next
  end
  if o.is_a?(Mutex) || o.is_a?(Monitor)
    next
  end
  # ivars
  o.instance_variables.each do |iv|
    begin; v = o.instance_variable_get(iv); rescue; next; end
    stack << [v, "#{path}.#{iv}", o, iv] if v
  end
  # array/hash elements
  if o.is_a?(Array)
    o.each_with_index { |e, i| stack << [e, "#{path}[#{i}]", o, nil] if e }
  elsif o.is_a?(Hash)
    o.each do |k, val|
      stack << [k, "#{path}.key", o, nil] if k
      stack << [val, "#{path}[#{k.inspect}]", o, nil] if val
    end
  end
end
puts "=== Found #{procs.size} Procs in app graph ==="

# --- Replace each Proc (repeat until stable — the same Proc can appear at
# multiple graph locations, and replacement can expose new ones) ---
# Don't dedup procs — the same proc object can live in many containers; we
# must replace every occurrence. Dedup non-proc objects to avoid cycles.
3.times do |pass|
  seen = {}
  procs = []
  stack = [[app, "app", nil, nil]]
  until stack.empty?
    o, path, parent, ivar = stack.pop
    next if o.nil?
    if o.is_a?(Proc)
      procs << [o, path, parent, ivar]
      next
    end
    next if seen[o.object_id]
    seen[o.object_id] = true
    next if o.is_a?(Mutex) || o.is_a?(Monitor)
    o.instance_variables.each do |iv|
      begin; v = o.instance_variable_get(iv); rescue; next; end
      stack << [v, "#{path}.#{iv}", o, iv] if v
    end
    if o.is_a?(Array)
      o.each_with_index { |e, i| stack << [e, "#{path}[#{i}]", o, nil] if e }
    elsif o.is_a?(Hash)
      o.each do |k, val|
        stack << [k, "#{path}.key", o, nil] if k
        stack << [val, "#{path}[#{k.inspect}]", o, nil] if val
      end
      # Hash default_proc — make_shareable traverses it
      dp = o.default_proc
      if dp
        procs << [dp, "#{path}.default_proc", o, :__default_proc__]
      end
    end
  end

  ssl_count = files_count = cookie_count = noop_count = 0
  procs.each do |proc_obj, path, parent, ivar|
    src = proc_obj.source_location&.first || ""
    replacement =
      if src.end_with?(SSL_LOC) && ivar == :@exclude
        redirect = parent.instance_variable_get(:@redirect)
        ssl_count += 1
        RactorRailsShim::CallableConst.new(!redirect)
      elsif src.end_with?(FILES_LOC) && ivar == :@app
        # Find the Files server via ActionDispatch::Static
        files_server = nil
        cur = mw
        while cur
          if cur.class.name == "ActionDispatch::Static"
            files_server = cur.instance_variable_get(:@file_server)
            break
          end
          cur = cur.instance_variable_get(:@app) rescue nil
        end
        files_server ||= parent
        files_count += 1
        RactorRailsShim::Callable.new(files_server, :get)
      elsif src.end_with?(COOKIE_LOC)
        cookie_count += 1
        RactorRailsShim::RequestCallable.new(:cookies_same_site_protection)
      else
        noop_count += 1
        RactorRailsShim::NoOpProc.new
      end

    if ivar == :__default_proc__
      parent.default = nil # clears the default_proc; the no-op callable can't serve as a Hash default
    elsif ivar
      parent.instance_variable_set(ivar, replacement) rescue nil
    elsif parent.is_a?(Array)
      idx = parent.index(proc_obj)
      if idx
        parent[idx] = replacement
      else
        parent.each_with_index { |e, i| parent[i] = replacement if e.equal?(proc_obj) }
      end
    elsif parent.is_a?(Hash)
      key = parent.key(proc_obj)
      parent[key] = replacement if key
    else
      # proc with no reconstructable parent — skip (will be caught next pass
      # via a different path, or is unreachable)
    end
  end
  puts "pass #{pass}: found #{procs.size} (ssl=#{ssl_count} files=#{files_count} cookie=#{cookie_count} noop=#{noop_count})"
  break if procs.empty?
end

# --- Replace all Mutex/Monitor with NoOpLock, and Concurrent::Map with
# frozen regular Hash (Concurrent::Map refuses #freeze) ---
seen2 = {}
stack = [[app, "app", nil, nil]]
until stack.empty?
  o, _p, parent, ivar = stack.pop
  next if o.nil? || seen2[o.object_id]
  seen2[o.object_id] = true
  if o.is_a?(Mutex) || o.is_a?(Monitor)
    next
  end
  o.instance_variables.each do |iv|
    begin; v = o.instance_variable_get(iv); rescue; next; end
    if v.is_a?(Mutex) || v.is_a?(Monitor)
      o.instance_variable_set(iv, RactorRailsShim::NoOpLock.new) rescue nil
    elsif defined?(Concurrent::Map) && v.is_a?(Concurrent::Map)
      # Replace with a regular Hash copy (Concurrent::Map refuses #freeze)
      hash_copy = {}
      v.each_pair { |k, val| hash_copy[k] = val }
      o.instance_variable_set(iv, hash_copy) rescue nil
    elsif v
      stack << [v, "#{_p}.#{iv}", o, iv]
    end
  end
  if o.is_a?(Array); o.each_with_index { |e,i| stack << [e, "#{_p}[#{i}]", o, nil] if e }
  elsif o.is_a?(Hash)
    o.each { |k,val| stack << [k, "#{_p}.key", o, nil] if k; stack << [val, "#{_p}[#{k.inspect}]", o, nil] if val }
  end
end
puts "=== Replaced Mutex/Monitor + Concurrent::Map ==="

# --- make_shareable ---
# Verify no Procs remain
seen3 = {}; remaining = 0; stack = [[app, "app"]]
until stack.empty?
  o, _ = stack.pop; next if o.nil? || seen3[o.object_id]; seen3[o.object_id] = true
  if o.is_a?(Proc); remaining += 1; next; end
  o.instance_variables.each { |iv| begin; v=o.instance_variable_get(iv); rescue; next; end; stack << [v, "#{_}.#{iv}"] if v }
  if o.is_a?(Array); o.each { |e| stack << [e, _] if e }
  elsif o.is_a?(Hash); o.each { |_, val| stack << [val, _] if val }
  end
end
puts "\n=== Remaining Procs: #{remaining} ==="
# Show where they are
seen4 = {}; rem = []; stack = [[app, "app"]]
until stack.empty?
  o, p = stack.pop; next if o.nil? || seen4[o.object_id]; seen4[o.object_id] = true
  if o.is_a?(Proc); rem << [p, o.source_location]; next; end
  o.instance_variables.each { |iv| begin; v=o.instance_variable_get(iv); rescue; next; end; stack << [v, "#{p}.#{iv}"] if v }
  if o.is_a?(Array); o.each_with_index { |e,i| stack << [e, "#{p}[#{i}]"] if e }
  elsif o.is_a?(Hash); o.each { |k,val| stack << [k, "#{p}.key"] if k; stack << [val, "#{p}[#{k.inspect}]"] if val }
  end
end
rem.first(20).each { |p, s| puts "  #{p}  #{s.inspect}" }

puts "\n=== Ractor.make_shareable(Rails.application) ==="
ms_result = begin
  Ractor.make_shareable(app)
  "SUCCEEDED: shareable=#{Ractor.shareable?(app)}"
rescue => e
  "FAILED: #{e.class}: #{e.message}"
end
# make_shareable may have frozen $stdout (logger holds an IO); write to a
# temp file to avoid the FrozenError on puts.
File.write("/tmp/phase3_probe_e_result.txt", ms_result + "\n")

# --- Worker dispatch ---
env_tmpl = Ractor.make_shareable({
  "REQUEST_METHOD" => "GET", "PATH_INFO" => "/up", "SCRIPT_NAME" => "",
  "QUERY_STRING" => "", "SERVER_NAME" => "localhost", "SERVER_PORT" => "9293",
  "HTTP_HOST" => "localhost", "rack.url_scheme" => "http",
})
dispatch_result = begin
  r = Ractor.new(app, env_tmpl) do |a, e|
    rack_env = e.to_h.merge(
      "rack.input" => StringIO.new(""), "rack.errors" => StringIO.new(""),
      "rack.version" => [3, 0],
    )
    s, h, b = a.call(rack_env)
    [s, h.keys, b.each.to_a.join.bytesize]
  rescue => ex
    [:err, ex.class.name, ex.message[0, 150], (ex.backtrace.first(3).join(" | "))]
  end
  "dispatch: #{r.value.inspect}"
rescue => e
  "spawn failed: #{e.class}: #{e.message[0,120]}"
end
File.write("/tmp/phase3_probe_e_result.txt", "#{ms_result}\n#{dispatch_result}\n", mode: "a")