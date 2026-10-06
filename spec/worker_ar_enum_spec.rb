# frozen_string_literal: true

# Worker-Ractor spec for the ActiveRecord enum patches (RAILS_FEATURES row
# 65). Rails enums generate four worker-hostile method families:
#
#   * predicates / bangs (`moderated?`, `moderated!`) — define_method'd with
#     Procs compiled inside `_enum_methods_module`, a Module the shim's
#     proc-replacement traversal cannot reach (it walks ivars, not included
#     modules' method tables). Worker calls raised "defined with an
#     un-shareable Proc in a different Ractor".
#   * the class-level values reader (`Post.states`) — singleton define_method
#     Proc; same un-shareable-Proc error in workers.
#   * per-value scopes (`Post.moderated`, `Post.not_moderated`) — scope-body
#     Procs capturing `name`/`value` locals; workers replayed them with a
#     lost binding and died on `NameError: undefined local variable or
#     method 'value'`.
#   * the attribute type registration — the enum's PendingDecorator holds a
#     decoration Proc (closure over `name`/`enum_values`/`validate`) that
#     Ruby refuses to make_shareable ("outer variable 'validate' may be
#     reassigned"). Without the fix the worker fell back to [] pending mods,
#     so the EnumType registration was lost: `p.state` cast to raw 0 and
#     `p.state = :moderated` cast to nil (silent data corruption).
#
# Fixes under test (both prepare-time, from _rebuild_activerecord_model_
# snapshots! / _prewarm_activerecord_memoizations!, before the graph freeze):
#
#   * _redefine_ar_enum_methods!  — string-eval'd REAL defs for predicates,
#     bangs, scopes and the pluralized values reader (const-backed).
#   * _share_ar_pending_attribute_modifications! — rebuilds the pending-mod
#     Structs with shareable members, swapping the undecoratable enum
#     decoration Proc for RactorRailsShim::EnumTypeDecorator (rebuilds a
#     fresh EnumType per apply, mirroring the upstream closure).
#
# Requires a real Rails test app + its bundle. Self-skips otherwise.
#
# Run (from the test app):
#   RAILS_SHIM_TEST_APP=/path/to/app bundle exec ruby \
#     -I<shim>/lib -I<shim>/spec <shim>/spec/worker_ar_enum_spec.rb

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/roles/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class WorkerArEnumSpec < Minitest::Spec
  require "tmpdir"
  DEFAULT_APP_DIR = ENV.fetch(
    "RAILS_SHIM_TEST_APP",
    File.join(Dir.tmpdir, "ractor-rails-shim-test-app")
  )

  def self.test_order
    :alpha
  end

  def setup
    super
    app_dir = DEFAULT_APP_DIR
    boot = File.join(app_dir, "config", "boot.rb")
    unless File.file?(boot)
      skip "No test Rails app at #{app_dir}. Set RAILS_SHIM_TEST_APP to an " \
           "existing app."
    end
    begin
      Gem::Specification.find_by_name("rails")
    rescue Gem::MissingSpecError
      skip "Rails gem not loadable in this bundle. Run this spec via the " \
           "test app's bundle."
    end
    @app_dir = app_dir
    @orig_dir = Dir.pwd
    @orig_rails_env = ENV["RAILS_ENV"]
  end

  def teardown
    ENV.delete("RAILS_ENV") if @orig_rails_env.nil?
    ENV["RAILS_ENV"] = @orig_rails_env if @orig_rails_env
    Dir.chdir(@orig_dir) if @orig_dir && @app_dir
    super
  end

  def self.probe(results, name)
    results[name] = yield
  rescue => ex
    results[:"#{name}_err"] = "#{ex.class}: #{ex.message[0, 120]}"
  end

  it "enum predicates, bangs, scopes, values reader and EnumType registration work in a worker" do
    Dir.chdir(@app_dir)
    ENV["RAILS_ENV"] = "production"
    ENV["SECRET_KEY_BASE"] ||= "dummy"

    require "ractor_rails_shim"
    RactorRailsShim.install
    require File.expand_path("config/boot", @app_dir)
    require File.expand_path("config/application", @app_dir)
    Bundler.require(*Rails.groups)
    Rails.application.initialize!

    RactorRailsShim.prepare_for_ractors! if RactorRailsShim.respond_to?(:prepare_for_ractors!)
    Rails.application.eager_load! rescue nil
    app = RactorRailsShim.make_app_shareable!(Rails.application)
    assert Ractor.shareable?(app), "app should be shareable after make_app_shareable!"

    worker = RactorRailsShim.worker_app!(app)
    assert Ractor.shareable?(worker), "worker app should be shareable"

    env_tmpl = Ractor.make_shareable({
      "REQUEST_METHOD" => "GET", "PATH_INFO" => "/up", "SCRIPT_NAME" => "",
      "QUERY_STRING" => "", "SERVER_NAME" => "localhost", "SERVER_PORT" => "9293",
      "HTTP_HOST" => "localhost", "rack.url_scheme" => "http",
    })

    r = Ractor.new(worker, env_tmpl) do |wa, e|
      rack_env = e.to_h.merge(
        "rack.input" => StringIO.new(""),
        "rack.errors" => StringIO.new(""),
        "rack.version" => [3, 0],
      )
      up_status, _, _ = wa.call(rack_env)
      results = { up_status: up_status }

      # EnumType registration (worker attribute rebuild replays the shared
      # pending mods — the EnumTypeDecorator builds a fresh EnumType here)
      WorkerArEnumSpec.probe(results, :type) do
        Post.attribute_types["state"].class.name
      end
      WorkerArEnumSpec.probe(results, :new_state) do
        Post.new(title: "t", body: "long enough body").state
      end
      WorkerArEnumSpec.probe(results, :assign_label) do
        p = Post.new(title: "t", body: "long enough body")
        p.state = :moderated
        p.state
      end
      # bang + predicates (real defs overriding _enum_methods_module)
      WorkerArEnumSpec.probe(results, :bang) do
        p = Post.new(title: "Probe", body: "long enough body")
        p.moderated!
        p.state
      end
      WorkerArEnumSpec.probe(results, :pred_after_bang) do
        p = Post.new(title: "Probe", body: "long enough body")
        p.moderated!
        [p.moderated?, p.draft?]
      end
      # class-level values reader (const-backed real def)
      WorkerArEnumSpec.probe(results, :states) { Post.states["moderated"] }
      # per-value scopes (positive + negative)
      WorkerArEnumSpec.probe(results, :scope_positive) { Post.moderated.to_a.size }
      WorkerArEnumSpec.probe(results, :scope_negative) { Post.not_moderated.to_a.size }
      # invalid value must raise like main (EnumType#assert_valid_value)
      WorkerArEnumSpec.probe(results, :invalid_raises) do
        begin
          Post.new.state = :bogus
          "no_raise"
        rescue ArgumentError
          "RAISE: ArgumentError"
        end
      end

      [up_status, results]
    end
    up_status, results = r.value

    assert up_status < 500, "GET /up must not 500 in a worker (got #{up_status})"
    refute results.key?(:type_err), "attribute_types failed in worker: #{results[:type_err]}"
    refute results.key?(:new_state_err), "state reader failed: #{results[:new_state_err]}"
    refute results.key?(:assign_label_err), "state assign failed: #{results[:assign_label_err]}"
    refute results.key?(:bang_err), "enum bang failed: #{results[:bang_err]}"
    refute results.key?(:pred_after_bang_err), "enum predicates failed: #{results[:pred_after_bang_err]}"
    refute results.key?(:states_err), "Post.states failed: #{results[:states_err]}"
    refute results.key?(:scope_positive_err), "enum scope failed: #{results[:scope_positive_err]}"
    refute results.key?(:scope_negative_err), "negative enum scope failed: #{results[:scope_negative_err]}"
    refute results.key?(:invalid_raises_err), "invalid assign failed: #{results[:invalid_raises_err]}"

    assert_equal "ActiveRecord::Enum::EnumType", results[:type],
                 "worker must rebuild the EnumType attribute registration"
    assert_equal "draft", results[:new_state],
                 "worker state reader must cast the column default through EnumType"
    assert_equal "moderated", results[:assign_label],
                 "worker `state = :moderated` must cast through EnumType (was nil before the fix)"
    assert_equal "moderated", results[:bang],
                 "worker `moderated!` must persist the enum label"
    assert_equal [true, false], results[:pred_after_bang],
                 "worker predicates must compare through state_for_database"
    assert_equal 1, results[:states],
                 "worker `Post.states` must return the frozen labels/values hash"
    assert_kind_of Integer, results[:scope_positive]
    assert_kind_of Integer, results[:scope_negative]
    assert_equal "RAISE: ArgumentError", results[:invalid_raises],
                 "worker invalid enum assignment must raise ArgumentError like main"
  end
end
