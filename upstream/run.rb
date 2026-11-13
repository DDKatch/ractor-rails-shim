# frozen_string_literal: true

# Upstream gem-suite harness.
#
# For each registered gem: clone the pinned ref, run its own test suite
# WITHOUT the shim (baseline), run it again WITH the shim loaded, and diff
# the failing test IDs. The pass criterion is: no test that passed in the
# baseline fails with the shim. Pre-existing upstream failures are expected
# and ignored — they are the baseline's own noise on this Ruby build.
#
# Usage:
#   ruby upstream/run.rb                 # all registered gems
#   ruby upstream/run.rb --only i18n     # one gem
#   ruby upstream/run.rb --list          # show registry
#
# Method doc: upstream/README.md

require "open3"
require "fileutils"
require "set"
require "timeout"

UPSTREAM_ROOT = File.expand_path(__dir__)
SHIM_ROOT     = File.expand_path("..", UPSTREAM_ROOT)
SHIM_LIB      = File.join(SHIM_ROOT, "lib")
CHECKOUTS     = File.join(UPSTREAM_ROOT, "checkouts")
GEMFILES      = File.join(UPSTREAM_ROOT, "gemfiles")
PRELUDE       = File.join(UPSTREAM_ROOT, "shim_prelude.rb")

# Registry: one entry per upstream gem to verify.
#
#   repo           clone URL
#   ref            pinned tag/commit (should match a PATCH_VERSIONS segment)
#   suite          argv that runs the suite, executed with cwd = checkout
#   dispatch_when  constant path(s) to force-load (const_get resolves
#                  autoloads) and then dispatch framework patches against,
#                  just before the suite executes. The shim itself is
#                  loaded earlier by shim_prelude.rb when the ROOT constant
#                  appears.
#   bundle_gemfile name of the Gemfile in upstream/gemfiles/ (default
#                  "<name>.rb")
GEMS = {
  "i18n" => {
    repo: "https://github.com/ruby-i18n/i18n.git",
    ref: "v1.15.2",
    suite: %w[bundle exec rake test TESTOPTS=-v],
    dispatch_when: "I18n::Config",
  },
  "rack" => {
    repo: "https://github.com/rack/rack.git",
    ref: "v3.2.8",
    suite: %w[bundle exec rake test:regular TESTOPTS=-v],
    dispatch_when: "Rack",
  },
  "marcel" => {
    repo: "https://github.com/rails/marcel.git",
    ref: "v1.2.1",
    suite: %w[bundle exec rake test TESTOPTS=-v],
    dispatch_when: "Marcel",
  },
  # tzinfo's Rakefile cannot load on Ruby 4 (rdoc/task removed from default
  # gems, gemspec eval fails), so the suite runs the three aggregator
  # scripts directly. They set conflicting global constants
  # (TZINFO_TEST_DATA_FORMAT, DataSource), so each needs its own process.
  # ts_all.rb collects test files via Dir["**/tc_*.rb"], so the injected
  # dispatch file must match that glob (tc_zz... sorts after the top-level
  # tc_* files; the format1/ subdir files that sort before it only define
  # format-specific test classes, no dispatch-relevant constants).
  "tzinfo" => {
    repo: "https://github.com/tzinfo/tzinfo.git",
    ref: "v2.0.6",
    suite: [
      %w[bundle exec ruby -Ilib test/ts_all_ruby_format1.rb -v],
      %w[bundle exec ruby -Ilib test/ts_all_ruby_format2.rb -v],
      %w[bundle exec ruby -Ilib test/ts_all_zoneinfo.rb -v],
    ],
    dispatch_file: "test/tc_zz_upstream_shim_dispatch.rb",
    dispatch_when: "TZInfo::DataSources",
  },
}.freeze

SUITE_TIMEOUT_S = 900

module Harness
  module_function

  # Run argv, return merged output and status (nil status means timeout).
  def run(argv, env: {}, cwd:, timeout: SUITE_TIMEOUT_S)
    out, status = Timeout.timeout(timeout) { Open3.capture2e(env, *argv, chdir: cwd) }
    [out, status]
  rescue ::Timeout::Error
    ["#{argv.join(' ')}: TIMEOUT after #{timeout}s", nil]
  end

  def ensure_checkout(name, spec)
    dir = File.join(CHECKOUTS, name)
    if File.directory?(File.join(dir, ".git"))
      run(%w[git fetch --quiet --tags], cwd: dir, timeout: 120) # best effort (offline ok)
    else
      FileUtils.mkdir_p(CHECKOUTS)
      argv = ["git", "clone", "--quiet", spec[:repo], dir]
      out, st = run(argv, cwd: CHECKOUTS, timeout: 300)
      raise "clone #{name} failed:\n#{out}" if st.nil? || !st.success?
    end
    out, st = run(["git", "checkout", "--quiet", spec[:ref]], cwd: dir, timeout: 120)
    raise "checkout #{spec[:ref]} for #{name} failed:\n#{out}" if st.nil? || !st.success?
    dir
  end

  def bundle_install(name, gemfile)
    env = {"BUNDLE_GEMFILE" => File.join(GEMFILES, gemfile)}
    out, st = run(%w[bundle install --quiet], env: env, cwd: GEMFILES, timeout: 600)
    raise "bundle install for #{name} failed:\n#{out}" if st.nil? || !st.success?
  end

  # Parse minitest verbose output:
  #   I18nSetLocaleTest#test_set_locale = 0.00 s = .
  # Capture "Klass#method" -> status letter. Also capture the summary line.
  TEST_LINE = /^\s*(\S+)#(\S+)\s+=\s+\d+\.\d+\s+s\s+=\s+([.FES])\s*$/
  SUMMARY   = /(\d+) runs, (\d+) assertions?, (\d+) failures?, (\d+) errors?, (\d+) skips?/

  def parse(output)
    failing = []
    runs = 0
    output.each_line do |line|
      if (m = line.match(TEST_LINE))
        failing << "#{m[1]}##{m[2]}" unless m[3] == "." # F, E, or S
      elsif (s = line.match(SUMMARY))
        runs = s[1].to_i
      end
    end
    {failing: failing, runs: runs}
  end

  def bundle_env(gemfile)
    {"BUNDLE_GEMFILE" => File.join(GEMFILES, gemfile)}
  end

  def shim_env(gemfile, dispatch_when)
    env = bundle_env(gemfile).merge(
      "RUBYOPT" => "-I#{SHIM_LIB} -r#{PRELUDE}",
    )
    dispatch_when = Array(dispatch_when).compact
    env["SHIM_DISPATCH_WHEN"] = dispatch_when.join(",") unless dispatch_when.empty?
    env
  end

  # The suite may be a single argv (most gems) or a list of argvs (gems that
  # need several isolated processes, e.g. tzinfo's three aggregators).
  # Returns [merged_output, status]: status is nil if any run timed out,
  # else the first non-zero exit status (0 if all ran clean).
  def run_suite(argvs, env, dir)
    outputs = []
    code = 0
    argvs.each do |argv|
      out, st = run(argv, env: env, cwd: dir)
      outputs << out
      return [outputs.join("\n"), nil] if st.nil?
      code = st.exitstatus if !st.exitstatus.zero? && code.zero?
    end
    [outputs.join("\n"), code == 0 ? 0 : 1]
  end

  def suite_argv(spec)
    s = spec[:suite]
    s.first.is_a?(Array) ? s : [s]
  end

  # The late-dispatch test file: copied into the checkout for the shim run
  # only. Its name must match the way the suite collects test files —
  # rake/minitest suites pick up "test/**/*_test.rb" (default) while suites
  # that glob "test/**/tc_*.rb" (tzinfo) need a dispatch_file entry that
  # matches their glob and sorts after the files that define the dispatch
  # targets. It runs after all test classes are defined but before tests
  # execute (minitest runs test methods at exit). It force-loads the
  # dispatch targets (const_get resolves autoloads) and aborts loudly if
  # the shim is missing — a silent no-shim run would otherwise produce a
  # vacuous PASS.
  DEFAULT_DISPATCH_FILE = "test/zz_upstream_shim_dispatch_test.rb"
  DISPATCH_BODY = <<~RUBY
    # Injected by upstream/run.rb — shim run only. Not a test; no test methods.
    abort "upstream harness: ractor_rails_shim NOT loaded" unless defined?(RactorRailsShim)
    %w[<%= TARGETS %>].each { |path| Object.const_get(path) }
    RactorRailsShim::Installer.dispatch_all_framework_patches
  RUBY

  def write_dispatch_file(dir, dispatch_when, file)
    targets = Array(dispatch_when).compact.join(",")
    body = DISPATCH_BODY.sub("<%= TARGETS %>", targets)
    path = File.join(dir, file)
    File.write(path, body)
    path
  end

  def remove_dispatch_file(dir, file)
    path = File.join(dir, file)
    File.delete(path) if File.exist?(path)
  end

  def fmt(result)
    "#{result[:runs]} runs, #{result[:failing].size} failing/skipped test lines"
  end

  def verify_one(name, spec)
    gemfile = spec[:bundle_gemfile] || "#{name}.rb"
    dispatch_file = spec[:dispatch_file] || DEFAULT_DISPATCH_FILE
    argvs = suite_argv(spec)
    puts "== #{name} @ #{spec[:ref]} =="
    dir = ensure_checkout(name, spec)
    remove_dispatch_file(dir, dispatch_file) # defensive: never let a stale file poison the baseline
    bundle_install(name, gemfile)

    base_out, base_st = run_suite(argvs, bundle_env(gemfile), dir)
    base = parse(base_out)
    puts "  baseline   : #{fmt(base)} (exit #{base_st.inspect})"

    write_dispatch_file(dir, spec[:dispatch_when], dispatch_file)
    shim_out, shim_st = run_suite(argvs, shim_env(gemfile, spec[:dispatch_when]), dir)
    remove_dispatch_file(dir, dispatch_file)
    shim = parse(shim_out)
    puts "  with shim  : #{fmt(shim)} (exit #{shim_st.inspect})"

    if base_st.nil? || shim_st.nil?
      puts "  VERDICT: FAIL — suite timed out (#{base_st.nil? ? "baseline" : "with shim"} run)"
      return :fail, []
    end

    baseline_failing = Set.new(base[:failing])
    new_failures = shim[:failing] - baseline_failing.to_a
    fixed        = baseline_failing - shim[:failing]
    count_shift  = shim[:runs] - base[:runs]

    verdict =
      if new_failures.any?
        :fail
      elsif count_shift.zero?
        :pass
      else
        :warn # no new failures, but test collection changed; investigate
      end

    case verdict
    when :pass
      puts "  VERDICT: PASS (no shim-induced regressions)"
    when :warn
      puts "  VERDICT: WARN — run count changed by #{count_shift}; investigate test collection"
    when :fail
      puts "  VERDICT: FAIL — #{new_failures.size} test(s) fail with the shim but not in the baseline:"
      new_failures.each { |t| puts "    - #{t}" }
    end
    if fixed.any?
      puts "  suspicious: #{fixed.size} test(s) pass in baseline but fail with shim (review)"
      fixed.each { |t| puts "    ? #{t}" }
    end
    [verdict, new_failures]
  end
end

if $PROGRAM_NAME == __FILE__
  args = ARGV.dup
  if args.delete("--list")
    GEMS.each { |name, spec| puts "#{name.ljust(20)} #{spec[:ref].to_s.ljust(10)} #{spec[:repo]}" }
    exit
  end
  only = nil
  if (i = args.index("--only"))
    only = args[i + 1]
    args[i, 2] = []
  end
  selected = only ? GEMS.slice(only) : GEMS
  if selected.empty?
    abort "no registered gem matches --only #{only.inspect}. See --list."
  end
  FileUtils.mkdir_p([CHECKOUTS, GEMFILES])

  problems = []
  selected.each do |name, spec|
    verdict, _new = Harness.verify_one(name, spec)
    problems << "#{name} (#{verdict})" unless verdict == :pass
  end

  puts
  if problems.empty?
    puts "UPSTREAM HARNESS: PASS — all #{selected.size} gem suite(s) clean under the shim."
  else
    puts "UPSTREAM HARNESS: FAIL — #{problems.join('; ')}"
    exit 1
  end
end
