# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

# Unit specs (no Rails dependency) — run under the shim's own bundle.
Rake::TestTask.new(:spec) do |t|
  t.libs << "lib"
  t.libs << "spec"
  t.pattern = "spec/**/*_spec.rb"
  t.warning = false
end

task default: :spec

# Integration spec: boots a real Rails app and dispatches GET /up in a worker
# Ractor. Requires a test app (run `./script/make_test_app.sh` first) and must
# run under the TEST APP's bundle (so Rails is loadable). The spec self-skips
# when Rails isn't available. Usage:
#   cd <test_app> && bundle exec ruby -I<shim>/lib -I<shim>/spec \
#     -e'require "minitest/autorun"; require "<shim>/spec/integration_spec.rb"'
desc "Run the integration spec against the test app (run from the test app dir)"
Rake::TestTask.new(:integration) do |t|
  t.libs << "lib"
  t.libs << "spec"
  t.pattern = "spec/integration_spec.rb"
  t.warning = false
end

# Run the FULL suite: unit specs (shim bundle) + integration spec (test app
# bundle, separate process). The two environment-gated specs
# (strategy_proc, integration) unskip under the test app's bundle where Rails
# is loadable. Requires a test app at RAILS_SHIM_TEST_APP (or
# ../ractor-rails-shim-test-app). To create one:
#   ./script/make_test_app.sh /tmp/ractor-rails-shim-test-app
# Usage (from the shim dir):
#   bundle exec rake all
desc "Run unit specs (shim bundle) + integration spec (test app bundle)"
task :all do
  require "tmpdir"
  app_dir = ENV.fetch("RAILS_SHIM_TEST_APP",
                      File.expand_path("../ractor-rails-shim-test-app", __dir__))
  unless File.file?(File.join(app_dir, "config", "boot.rb"))
    abort "No test app at #{app_dir}. Run `./script/make_test_app.sh #{app_dir}` first."
  end
  shim_dir = __dir__
  base_env = {
    "RAILS_SHIM_TEST_APP" => app_dir,
    "RAILS_ENV" => "production",
    "SECRET_KEY_BASE" => "dummy",
    "BUNDLE_GEMFILE" => nil,
  }
  rubyopt = "-I#{shim_dir}/lib -I#{shim_dir}/spec"

  # 1. Unit suite under the shim's own bundle (fast, no Rails boot).
  Rake::Task[:spec].invoke

  # 2. strategy_proc under the test app's bundle (loads action_dispatch but
  #    doesn't boot Rails — separate process to avoid contaminating the
  #    integration spec's make_app_shareable! graph).
  Dir.chdir(app_dir) do
    sh(base_env,
       "bundle exec ruby #{rubyopt} -e '" \
       "require \"minitest/autorun\"; " \
       "require \"#{shim_dir}/spec/strategy_proc_spec.rb\"'")
  end

  # 3. Integration spec (full Rails boot, own process — make_app_shareable!
  #    deep-freezes Rails constants).
  Dir.chdir(app_dir) do
    sh(base_env,
       "bundle exec ruby #{rubyopt} -e '" \
       "require \"minitest/autorun\"; " \
       "require \"#{shim_dir}/spec/integration_spec.rb\"'")
  end
end
