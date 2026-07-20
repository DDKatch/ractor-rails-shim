# frozen_string_literal: true

# Integration / smoke test: boots a real (minimal) Rails app, makes it
# shareable via RactorRailsShim.make_app_shareable!, dispatches GET /up in a
# worker Ractor, and asserts a 200 response. This is the productionize-quality
# guard that the unit specs (which use fake modules) can't provide.
#
# The test app is NOT bundled with the gem (it's large and Rails-version
# specific). Instead this spec expects one to exist at the path given by the
# RAILS_SHIM_TEST_APP env var (or the Phase-3 default tmp path). If no test app
# is present, the spec self-skips with instructions to run
# `./script/make_test_app.sh` first.
#
# Run:
#   ./script/make_test_app.sh        # once, to create the test app
#   RAILS_SHIM_TEST_APP=/path/to/test_app bundle exec ruby spec/integration_spec.rb
#
# Or via Rake: `bundle exec rake spec` (this file is picked up by the
# spec/**/*_spec.rb pattern in Rakefile).

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class IntegrationSpec < Minitest::Spec
  # Resolve the test app directory. Allow override via env var; default to a
  # platform-appropriate tmp location (NOT the author's machine-specific macOS
  # path). `Dir.tmpdir` requires the `tmpdir` stdlib.
  require "tmpdir"
  DEFAULT_APP_DIR = ENV.fetch(
    "RAILS_SHIM_TEST_APP",
    File.join(Dir.tmpdir, "ractor-rails-shim-test-app")
  )

  def self.test_order
    :alpha
  end

  # Skip the whole spec unless a bootable Rails app is present at the
  # configured path AND its bundle is loadable from this process (i.e. the
  # spec is run via the test app's `bundle exec`, not the shim's own bundle).
  # Prints instructions otherwise.
  def setup
    super
    app_dir = DEFAULT_APP_DIR
    boot = File.join(app_dir, "config", "boot.rb")
    gemfile = File.join(app_dir, "Gemfile")
    unless File.file?(boot)
      skip "No test Rails app at #{app_dir}. Run " \
           "`./script/make_test_app.sh #{app_dir}` first to create one, " \
           "or set RAILS_SHIM_TEST_APP to an existing app."
    end
    # The test app's bundle must be active. We detect this by checking whether
    # `rails` is resolvable with the current load path. If not, the spec was
    # likely run under the shim's own bundle (which has no Rails) — skip with
    # instructions.
    begin
      Gem::Specification.find_by_name("rails")
    rescue Gem::MissingSpecError
      skip "Rails gem not loadable in this bundle. Run the integration spec " \
           "via the test app's bundle, e.g.: " \
           "`cd #{app_dir} && bundle exec ruby -I<shim>/lib " \
           "-I<shim>/spec -e 'require \"minitest/autorun\"; " \
           "require \"<shim>/spec/integration_spec.rb\"`"
    end
    @app_dir = app_dir
    # Capture pre-test process state so we can restore it in teardown. Note
    # that `Rails.application.initialize!` is irreversible within a process,
    # so this spec can only run once per Ruby process — re-running the suite
    # in the same process will skip/fail on the second `initialize!`. That is
    # a documented limitation of in-process Rails boot, not a spec bug.
    @orig_dir = Dir.pwd
    @orig_rails_env = ENV["RAILS_ENV"]
  end

  def teardown
    # Restore CWD + RAILS_ENV. We deliberately do NOT attempt to un-initialize
    # Rails.application (impossible) — see the note in #setup.
    ENV.delete("RAILS_ENV") if @orig_rails_env.nil?
    ENV["RAILS_ENV"] = @orig_rails_env if @orig_rails_env
    Dir.chdir(@orig_dir) if @orig_dir && @app_dir
    super
  end

  it "a worker Ractor dispatches GET /up and returns HTTP 200" do
    Dir.chdir(@app_dir)
    ENV["RAILS_ENV"] = "production"
    ENV["SECRET_KEY_BASE"] ||= "dummy"

    # Boot the app the way config_ractor.ru does: install the shim BEFORE
    # Rails loads so the framework patches are in place before any unshareable
    # Procs are captured. `make_app_shareable!` re-runs `_install_all_framework
    # _patches` idempotently, but it runs AFTER `initialize!` — too late for
    # classes that captured bindings during boot. The rackup files install the
    # shim at this same phase (before `require_relative "config/application"`);
    # this spec mirrors that sequence so it exercises the real boot path
    # rather than the (now-removed) config/boot.rb auto-install hook.
    require "ractor_rails_shim"
    RactorRailsShim.install
    require File.expand_path("config/boot", @app_dir)
    require File.expand_path("config/application", @app_dir)
    Bundler.require(*Rails.groups)
    Rails.application.initialize!

    app = RactorRailsShim.make_app_shareable!(Rails.application)
    assert Ractor.shareable?(app), "app should be shareable after make_app_shareable!"

    env_tmpl = Ractor.make_shareable({
      "REQUEST_METHOD" => "GET", "PATH_INFO" => "/up", "SCRIPT_NAME" => "",
      "QUERY_STRING" => "", "SERVER_NAME" => "localhost", "SERVER_PORT" => "9293",
      "HTTP_HOST" => "localhost", "rack.url_scheme" => "http",
    })

    r = Ractor.new(app, env_tmpl) do |a, e|
      rack_env = e.to_h.merge(
        "rack.input" => StringIO.new(""),
        "rack.errors" => StringIO.new(""),
        "rack.version" => [3, 0],
      )
      begin
        status, headers, body = a.call(rack_env)
        [status, headers["content-type"], body.each.to_a.join]
      rescue => ex
        root = ex
        root = root.cause while root.cause
        [:err, ex.class.name, ex.message[0, 150],
         "ROOT: #{root.class.name}: #{root.message[0, 150]}"]
      end
    end
    result = r.value

    refute_equal :err, result.first, "dispatch failed: #{result.inspect}"
    assert_equal 200, result[0], "expected HTTP 200, got #{result[0].inspect}"
    assert_match %r{text/html}, result[1].to_s, "expected text/html content-type"
    assert_match %r{<!DOCTYPE html>}, result[2].to_s, "expected the health-check HTML body"
  end
end