# frozen_string_literal: true

# Phase 3 probe C: production mode. Check which Procs remain in the app
# graph and whether make_shareable succeeds after lock replacement.

APP_DIR = File.expand_path(ARGV[0] || Dir.pwd)
Dir.chdir(APP_DIR)
ENV["RAILS_ENV"] ||= "production"
ENV["SECRET_KEY_BASE"] ||= "dummy"
require File.join(APP_DIR, "config/boot")
require File.join(APP_DIR, "config/application")
Rails.application.initialize!
RactorRailsShim.prepare_for_ractors!

class NopLock
  def synchronize; yield; end
  def mon_synchronize; yield; end
  def lock; self; end
  def unlock; self; end
  def locked?; false; end
  def mon_enter; end
  def mon_exit; end
  def new_cond; Object.new; end
end

app = Rails.application

# Replace all Mutex/Monitor with NopLock
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
      o.instance_variable_set(iv, NopLock.new) rescue nil
    elsif v && !v.frozen?
      stack << [v, "#{_p}.#{iv}"]
    end
  end
end

# Find remaining unshareable Procs
seen2 = {}
found = []
stack = [[app, "app"]]
until stack.empty?
  o, p = stack.pop
  next if o.nil? || seen2[o.object_id]
  seen2[o.object_id] = true
  if o.is_a?(Proc)
    found << [p, o.source_location, Ractor.shareable?(o)]
    next
  end
  next if o.frozen? && Ractor.shareable?(o)
  o.instance_variables.each do |iv|
    begin; v = o.instance_variable_get(iv); rescue; next; end
    stack << [v, "#{p}.#{iv}"] if v && !v.frozen?
  end
end
puts "=== Unshareable Procs in production app graph (#{found.size}) ==="
found.each { |p, s, sh| puts "  #{p}  src=#{s.inspect}  shareable=#{sh}" }

puts "\n=== Ractor.make_shareable ==="
begin
  Ractor.make_shareable(app)
  puts "OK: shareable=#{Ractor.shareable?(app)}"
  # Try a worker dispatch
  env = Ractor.make_shareable(
    "REQUEST_METHOD" => "GET", "PATH_INFO" => "/up", "SCRIPT_NAME" => "",
    "QUERY_STRING" => "", "SERVER_NAME" => "localhost", "SERVER_PORT" => "9293",
    "HTTP_HOST" => "localhost", "rack.url_scheme" => "http"
  )
  r = Ractor.new(app, env) do |a, e|
    rack_env = e.to_h.merge(
      "rack.input" => StringIO.new(""), "rack.errors" => StringIO.new(""),
      "rack.version" => [3, 0],
    )
    s, h, b = a.call(rack_env)
    [s, h.keys, b.each.to_a.join.bytesize]
  rescue => ex
    [:err, ex.class.name, ex.message[0, 120]]
  end
  puts "worker dispatch: #{r.value.inspect}"
rescue => e
  puts "FAIL: #{e.class}: #{e.message[0, 150]}"
  puts "  bt: #{e.backtrace.first(3).join("\n  ")}"
end