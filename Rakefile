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

task default: :spec
