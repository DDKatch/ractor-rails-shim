# frozen_string_literal: true

# Phase 3 probe B: test the make-shareable strategy. Replace every
# Mutex/Monitor in Rails.application's object graph with a Ractor-safe
# no-op lock (the app is shared read-only in ractor mode, so the locks are
# never contended post-boot), then try Ractor.make_shareable and a worker
# dispatch.

APP_DIR = File.expand_path(ARGV[0] || Dir.pwd)
Dir.chdir(APP_DIR)
require File.join(APP_DIR, "config/boot")
require File.join(APP_DIR, "config/application")
Rails.application.initialize!
RactorRailsShim.prepare_for_ractors!

# A no-op lock that quacks like Mutex and Monitor. Ractor.make_shareable
# succeeds on it (it's a plain object with no unshareable refs). In ractor
# mode the shared app is read-only, so the locks are never contended; a
# no-op is correct. Subclassing Mutex/Monitor is impossible (allocator),
# but duck-typing works because callers use `lock.synchronize { ... }`.
class RactorRailsShim::NoOpLock
  def synchronize; yield; end
  def lock; self; end
  def unlock; self; end
  def locked?; false; end
  def try_lock; true; end
  def locked; false; end
  def sleep(_t = nil); end
  def mon_enter; end
  def mon_exit; end
  def mon_try_enter; true; end
  def mon_synchronize; yield; end
  def mon_locked?; false; end
  def new_cond; Struct.new(:wait, :signal, :broadcast).new(-> {}, -> {}, -> {}) end
  def respond_to_missing?(_name, _inc = false); true; end
end

# Walk the app graph and replace every Mutex/Monitor with a NoOpLock.
app = Rails.application
seen = {}
replaced = []
stack = [[app, "app"]]
until stack.empty?
  obj, path = stack.pop
  next if obj.nil?
  next if seen[obj.object_id]
  seen[obj.object_id] = true
  if obj.is_a?(Mutex) || obj.is_a?(Monitor)
    replaced << path
    next # can't replace in-place without the parent; handle below
  end
  next if obj.frozen? && Ractor.shareable?(obj)
  obj.instance_variables.each do |iv|
    begin
      v = obj.instance_variable_get(iv)
    rescue
      next
    end
    if v.is_a?(Mutex) || v.is_a?(Monitor)
      begin
        obj.instance_variable_set(iv, RactorRailsShim::NoOpLock.new)
        replaced << path + ".#{iv}"
      rescue => e
        replaced << path + ".#{iv} (FAILED: #{e.class})"
      end
    else
      stack << [v, "#{path}.#{iv}"] if v && !v.frozen?
    end
  end
end
puts "=== Replaced #{replaced.size} Mutex/Monitor ==="
replaced.each { |p| puts "  #{p}" }

# Now try make_shareable
puts "\n=== Ractor.make_shareable(Rails.application) ==="
begin
  Ractor.make_shareable(app)
  puts "SUCCEEDED: app is shareable? #{Ractor.shareable?(app)}"
rescue => e
  puts "FAILED: #{e.class}: #{e.message[0,150]}"
  puts "  bt: #{e.backtrace.first(3).join("\n  ")}"
end

# Try a worker dispatch
puts "\n=== Worker dispatch via shared app ==="
env_tmpl = {
  REQUEST_METHOD: "GET", PATH_INFO: "/up", SCRIPT_NAME: "",
  QUERY_STRING: "", SERVER_NAME: "localhost", SERVER_PORT: "9293",
  HTTP_HOST: "localhost", "rack.url_scheme" => "http",
}
env_tmpl = Ractor.make_shareable(env_tmpl)
begin
  r = Ractor.new(app, env_tmpl) do |a, e|
    rack_env = e.to_h.merge(
      "rack.input" => StringIO.new(""), "rack.errors" => StringIO.new(""),
      "rack.version" => [3, 0],
    )
    s, h, b = a.call(rack_env)
    [s, h.keys, b.each.to_a.join.bytesize]
  rescue => ex
    [:err, ex.class.name, ex.message[0,120]]
  end
  res = r.value
  puts "result: #{res.inspect}"
rescue => e
  puts "spawn failed: #{e.class}: #{e.message[0,120]}"
end