# Phase 2 probe: with the shim installed, test (a) whether Ractor.make_shareable
# works on Rails.application, and (b) whether reading the shareable-rerouted
# accessors from a worker ractor works without IsolationError.
#
# Mirrors kino/doc/rails-on-ractors.md blockers #1 and #2.
#
# Usage: run from a Rails app dir that has the shim in its Gemfile and
# installed in config/boot.rb. E.g.:
#   bundle exec ruby ../../ractor-rails-shim/phase2_probe.rb
# from the test_app dir, or:
#   cd <test_app> && bundle exec ruby <shim>/phase2_probe.rb

# config/boot.rb installs the shim (bundler.setup + RactorRailsShim.install).
# Accept an app dir as the first arg (default: the current dir).
APP_DIR = File.expand_path(ARGV[0] || Dir.pwd)
Dir.chdir(APP_DIR)
require File.join(APP_DIR, "config/boot")

# Load config.ru like Kino does, to build the Rack app.
require "rack"
rack_app, _ = Rack::Builder.parse_file(File.expand_path("config.ru", APP_DIR))
rack_app = rack_app.first if rack_app.is_a?(Array)

puts "=== App built ==="
puts "app.class = #{rack_app.class}"
puts "Ractor.shareable?(app) = #{Ractor.shareable?(rack_app)}"

# --- Blocker #1: make_shareable(Rails.application) ---
puts "\n=== Blocker #1: Ractor.make_shareable(Rails.application) ==="
begin
  Ractor.make_shareable(Rails.application)
  puts "SUCCEEDED: Ractor.make_shareable(Rails.application) ok"
rescue Ractor::IsolationError => e
  puts "FAILED: #{e.class}: #{e.message}"
  puts "  backtrace top: #{e.backtrace.first(3).join("\n  ")}"
rescue => e
  puts "ERROR: #{e.class}: #{e.message}"
  puts "  backtrace top: #{e.backtrace.first(3).join("\n  ")}"
end

# --- Blocker #1b: locate the Monitor (the first blocker for make_shareable) ---
puts "\n=== Blocker #1b: locate Monitor/Mutex in Rails.application graph ==="
def find_unshareable(obj, path = "app", depth = 0, seen = {}, &block)
  return if depth > 8
  return if seen[obj.object_id]
  seen[obj.object_id] = true
  if obj.is_a?(Monitor) || obj.is_a?(Mutex)
    yield "#{path} = #{obj.class} (#{obj.inspect[0,60]})"
    return
  end
  return if obj.frozen? && Ractor.shareable?(obj)
  obj.instance_variables.each do |iv|
    begin
      v = obj.instance_variable_get(iv)
    rescue => e
      v = nil
    end
    find_unshareable(v, "#{path}.#{iv}", depth + 1, seen, &block) if v
  end
end
found = []
find_unshareable(Rails.application) { |loc| found << loc }
found.first(10).each { |loc| puts "  #{loc}" }
puts "  (#{found.size} Monitor/Mutex found in app graph)" unless found.empty?

# --- Blocker #2: call the app from a worker ractor ---
puts "\n=== Blocker #2: dispatch a request from a worker ractor ==="
env = {
  "REQUEST_METHOD" => "GET",
  "PATH_INFO" => "/up",
  "rack.input" => StringIO.new,
  "rack.errors" => StringIO.new,
  "SCRIPT_NAME" => "",
  "QUERY_STRING" => "",
  "SERVER_NAME" => "localhost",
  "SERVER_PORT" => "9293",
  "HTTP_HOST" => "localhost",
  "rack.version" => [3, 0],
  "rack.url_scheme" => "http",
}.freeze

# Make a shareable proc wrapping the app so we can pass it to a ractor.
begin
  shareable_app = Ractor.shareable_proc do |a, e|
    a.call(e)
  end
  r = Ractor.new(rack_app, env, shareable_app) do |a, e, sa|
    sa.call(a, e)
  end
  status, headers, body = r.value
  puts "SUCCEEDED: status=#{status.inspect}"
  puts "  headers keys: #{headers.keys.inspect}"
  body_str = body.each.to_a.join
  puts "  body: #{body_str.inspect[0,120]}"
rescue Ractor::IsolationError => e
  puts "FAILED: #{e.class}: #{e.message}"
  puts "  backtrace top: #{e.backtrace.first(3).join("\n  ")}"
rescue => e
  puts "ERROR: #{e.class}: #{e.message}"
  puts "  backtrace top: #{e.backtrace.first(5).join("\n  ")}"
end

# --- Direct ivar-read probe (shim target) ---
puts "\n=== Shim target check: read Rails.application from a worker ractor ==="
# First, confirm the shim patched Rails.application in the main ractor.
puts "main: Rails.method(:application).source_location = #{Rails.method(:application).source_location.inspect}"
puts "main: Rails.application.class = #{Rails.application.class}"
r = Ractor.new do
  begin
    sl = Rails.method(:application).source_location
    [ :ok, sl, Rails.application.class.name, Rails.env, ActionDispatch::ExceptionWrapper.rescue_responses.class ]
  rescue Ractor::IsolationError => ie
    [ :isolation_error, ie.message ]
  rescue => ex
    [ :error, ex.class.name, ex.message ]
  end
end
result = r.value
if result.first == :ok
  puts "SUCCEEDED: #{result.inspect}"
else
  puts "FAILED: #{result.inspect}"
end