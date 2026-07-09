# frozen_string_literal: true

# Phase 3 probe: test whether a worker Ractor can boot its own Rails.application
# (own locks, own autoloaders) and serve a request, bypassing Ractor.make_shareable
# entirely.
#
# Strategy:
#   1. Main Ractor boots Rails normally (config/boot + config/application + initialize!).
#      This sets Rails.application in main's IES slot and TestApp::Application@instance.
#   2. A worker Ractor boots its OWN app instance: it creates a fresh
#      TestApp::Application, runs initialize!, assigns Rails.application, and
#      serves a request. Each Ractor gets its own Mutex/Monitor graph because
#      they're created at app.new time inside that Ractor.
#
# The shim enables step 2: class-ivar/constant reads that would raise
# IsolationError from a worker are rerouted, so the worker can run the
# initializer chain (which reads Rails.application, Rails.env,
# rescue_responses, etc.) without error.
#
# Usage: run from a Rails app dir that has the shim in its Gemfile and
# installed in config/boot.rb. E.g.:
#   cd <test_app> && bundle exec ruby <shim>/phase3_probe.rb

APP_DIR = File.expand_path(ARGV[0] || Dir.pwd)
Dir.chdir(APP_DIR)

# config/boot.rb installs the shim.
require File.join(APP_DIR, "config/boot")
# config/application.rb defines TestApp::Application and calls Bundler.require.
require File.join(APP_DIR, "config/application")
Rails.application.initialize!
RactorRailsShim.prepare_for_ractors!

puts "=== Main Ractor booted ==="
puts "Rails.app_class = #{Rails.app_class}"
puts "Rails.application.class = #{Rails.application.class}"
puts "Rails.application.object_id = #{Rails.application.object_id}"

# Build a shareable request env to pass to the worker. Strings frozen by
# frozen_string_literal; Arrays/IO need make_shareable.
env = {
  REQUEST_METHOD: "GET",
  PATH_INFO: "/up",
  SCRIPT_NAME: "",
  QUERY_STRING: "",
  SERVER_NAME: "localhost",
  SERVER_PORT: "9293",
  HTTP_HOST: "localhost",
  "rack.url_scheme" => "http",
}
env = Ractor.make_shareable(env)

# Pass the app_class NAME (a frozen String, shareable) to the worker. The
# worker resolves the constant itself (constants are shareable once the class
# is defined; class objects are shareable in Ruby 4.0).
app_class_name = Ractor.make_shareable("TestApp::Application")

worker = Ractor.new(app_class_name, env) do |cls_name, request_env|
  begin
    # Resolve the app class from its name. Class objects are shareable, so
    # reading the constant from a worker is allowed once it's defined (the
    # main Ractor loaded config/application.rb, which defines TestApp).
    app_class = Object.const_get(cls_name)

    # Boot a FRESH app instance in this Ractor. Each Ractor gets its own
    # Mutex/Monitor graph because app.new + initialize! create them here.
    app = app_class.new
    app.initialize!

    # Assign to the per-Ractor Rails.application slot (shim routes through IES).
    Rails.application = app

    # Sanity: read back what we set.
    app_read = Rails.application
    app_env = Rails.env

    # Build a Rack env hash the way Rack::Test would, with a StringIO input.
    # StringIO.new is not shareable, so create it inside the Ractor.
    rack_env = {
      "REQUEST_METHOD" => request_env[:REQUEST_METHOD],
      "PATH_INFO"       => request_env[:PATH_INFO],
      "SCRIPT_NAME"     => request_env[:SCRIPT_NAME],
      "QUERY_STRING"    => request_env[:QUERY_STRING],
      "SERVER_NAME"     => request_env[:SERVER_NAME],
      "SERVER_PORT"     => request_env[:SERVER_PORT],
      "HTTP_HOST"       => request_env[:HTTP_HOST],
      "rack.url_scheme" => request_env["rack.url_scheme"],
      "rack.input"      => StringIO.new(""),
      "rack.errors"     => StringIO.new(""),
      "rack.version"    => [3, 0],
    }

    status, headers, body = app.call(rack_env)
    body_str = body.each.to_a.join
    {
      result: :ok,
      app_class: app_class.name,
      app_oid: app.object_id,
      app_read_oid: app_read.object_id,
      env: app_env.to_s,
      status: status,
      header_keys: headers.keys,
      body_size: body_str.bytesize,
      body_head: body_str[0, 80],
    }
  rescue Ractor::IsolationError => e
    { result: :isolation_error, class: e.class.name, msg: e.message[0, 200], bt: e.backtrace.first(5) }
  rescue => e
    { result: :error, class: e.class.name, msg: e.message[0, 200], bt: e.backtrace.first(8) }
  end
end

result = worker.value
puts "\n=== Worker Ractor result ==="
if result[:result] == :ok
  puts "SUCCEEDED"
  puts "  app.class      = #{result[:app_class]}"
  puts "  app.object_id  = #{result[:app_oid]} (main's was #{Rails.application.object_id})"
  puts "  app read back  = #{result[:app_read_oid]} (same? #{result[:app_read_oid] == result[:app_oid]})"
  puts "  Rails.env      = #{result[:env]}"
  puts "  HTTP status    = #{result[:status]}"
  puts "  headers        = #{result[:header_keys].inspect}"
  puts "  body size      = #{result[:body_size]} bytes"
  puts "  body head      = #{result[:body_head].inspect}"
else
  puts "FAILED: #{result[:class]}: #{result[:msg]}"
  puts result[:bt]&.join("\n  ")
end