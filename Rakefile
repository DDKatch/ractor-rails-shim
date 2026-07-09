# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:spec) do |t|
  t.libs << "lib"
  t.libs << "spec"
  t.pattern = "spec/**/*_spec.rb"
  t.warning = false
end

task default: :spec