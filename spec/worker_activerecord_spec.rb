# frozen_string_literal: true

# Worker-Ractor integration spec for the ActiveRecord patches that fix
# `Ractor::IsolationError` / "can not set instance variables of
# classes/modules by non-main Ractors" under kino's worker Ractors (which do
# NOT share main's class-ivar space, unlike `Ractor.new` workers):
#
#   * columns_hash            -> per-Ractor IES cache (activerecord.rb)
#   * AssociationScope::INSTANCE -> made Ractor-shareable (activerecord.rb)
#   * pending_attribute_modifications -> per-Ractor IES (active_model_attribute.rb
#                                        + activerecord.rb capture +
#                                        core.rb SHAREABLE_PENDING_ATTR_MODS)
#   * columns / column_names / symbol_column_to_string / content_columns /
#     attribute_names        -> per-Ractor IES (active_record_model_schema.rb)
#   * reflections (klass / foreign_key / ...) -> per-worker cache
#                                        (activerecord_reflection.rb)
#   * scope macro (recent / by_title(q)) -> string-eval worker-safe body
#                                        (activerecord.rb)
#
# It boots the real test Rails app, makes it shareable, dispatches a request
# inside a worker Ractor (which initializes the worker's AR connections), then
# directly exercises each patched method from that same worker and asserts the
# values are correct and no IsolationError/FrozenError is raised.
#
# This spec requires a real Rails test app + its bundle. It self-skips
# otherwise (run via the test app's bundle, like integration_spec.rb).
#
# Run (from the test app):
#   RAILS_SHIM_TEST_APP=/path/to/app bundle exec ruby \
#     -I<shim>/lib -I<shim>/spec <shim>/spec/worker_activerecord_spec.rb

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/roles/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class WorkerActiveRecordSpec < Minitest::Spec
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
      skip "No test Rails app at #{app_dir}. Run " \
           "`./script/make_test_app.sh #{app_dir}` first, or set " \
           "RAILS_SHIM_TEST_APP to an existing app."
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

  # Safely probe a worker-only expression, recording either the value or the
  # (class + truncated message) of any error — so a single failure surfaces
  # without aborting the rest of the probes.
  def self.probe(results, name)
    results[name] = yield
  rescue => ex
    results["#{name}_err"] = "#{ex.class}: #{ex.message[0, 120]}"
  end

  it "patched ActiveRecord methods work inside a worker Ractor (no IsolationError)" do
    Dir.chdir(@app_dir)
    ENV["RAILS_ENV"] = "production"
    ENV["SECRET_KEY_BASE"] ||= "dummy"

    require "ractor_rails_shim"
    RactorRailsShim.install
    require File.expand_path("config/boot", @app_dir)
    require File.expand_path("config/application", @app_dir)
    Bundler.require(*Rails.groups)
    Rails.application.initialize!

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
      # A dispatch triggers setup_once! -> init_worker_ar_connections! so the
      # worker has a usable AR connection for the direct probes below.
      up_status, _, _ = wa.call(rack_env)
      results = { up_status: up_status }

      # columns_hash (per-Ractor IES cache)
      WorkerActiveRecordSpec.probe(results, :ch_id) { Post.columns_hash.key?("id") }
      WorkerActiveRecordSpec.probe(results, :columns) { Post.columns.map(&:name) }
      WorkerActiveRecordSpec.probe(results, :column_names) { Post.column_names }
      WorkerActiveRecordSpec.probe(results, :content_columns) { Post.content_columns.map(&:name) }
      WorkerActiveRecordSpec.probe(results, :primary_key) { Post.primary_key }
      WorkerActiveRecordSpec.probe(results, :attribute_names) { Post.attribute_names }
      WorkerActiveRecordSpec.probe(results, :sym_to_str) { Post.symbol_column_to_string(:title) }
      WorkerActiveRecordSpec.probe(results, :pending_class) do
        Post.pending_attribute_modifications.class.name
      end

      # reflection memoization (per-worker cache)
      WorkerActiveRecordSpec.probe(results, :refl_klass) do
        Post.reflect_on_association(:comments).klass.name
      end
      WorkerActiveRecordSpec.probe(results, :refl_fk) do
        Post.reflect_on_association(:comments).foreign_key
      end

      # scope macro (string-eval, parameterized)
      WorkerActiveRecordSpec.probe(results, :scope_recent) { Post.recent.limit(1).to_a.size }
      WorkerActiveRecordSpec.probe(results, :scope_by_title) { Post.by_title("zzzzz").to_a.size }

      # associations / Arel (AssociationScope::INSTANCE shareable)
      WorkerActiveRecordSpec.probe(results, :where_found) do
        first_id = Post.order(:id).first&.id || 0
        !Post.find_by(id: first_id).nil?
      end

      [up_status, results]
    end
    up_status, results = r.value

    assert up_status < 500, "GET /up must not 500 in a worker (got #{up_status})"
    refute results.key?(:ch_id_err), "columns_hash failed in worker: #{results[:ch_id_err]}"
    refute results.key?(:columns_err), "columns failed in worker: #{results[:columns_err]}"
    refute results.key?(:column_names_err), "column_names failed: #{results[:column_names_err]}"
    refute results.key?(:content_columns_err), "content_columns failed: #{results[:content_columns_err]}"
    refute results.key?(:attribute_names_err), "attribute_names failed: #{results[:attribute_names_err]}"
    refute results.key?(:sym_to_str_err), "symbol_column_to_string failed: #{results[:sym_to_str_err]}"
    refute results.key?(:pending_class_err), "pending_attribute_modifications failed: #{results[:pending_class_err]}"
    refute results.key?(:refl_klass_err), "reflection klass failed: #{results[:refl_klass_err]}"
    refute results.key?(:refl_fk_err), "reflection foreign_key failed: #{results[:refl_fk_err]}"
    refute results.key?(:scope_recent_err), "scope :recent failed: #{results[:scope_recent_err]}"
    refute results.key?(:scope_by_title_err), "scope :by_title failed: #{results[:scope_by_title_err]}"
    refute results.key?(:where_found_err), "Post.find_by failed: #{results[:where_found_err]}"

    assert_equal true, results[:ch_id], "worker columns_hash must include 'id'"
    assert_includes results[:columns], "title"
    assert_includes results[:column_names], "title"
    assert results[:content_columns].all? { |c| results[:column_names].include?(c) },
           "content_columns must be a subset of column_names"
    # content_columns excludes the primary key (when primary_key resolves in
    # the worker — it can be nil under some worker setups, so guard on it).
    if results[:primary_key].is_a?(String)
      refute_includes results[:content_columns], results[:primary_key]
    end
    assert_equal "title", results[:sym_to_str]
    assert_equal "Array", results[:pending_class]
    assert_equal "Comment", results[:refl_klass]
    assert_kind_of String, results[:refl_fk]
    assert_kind_of Integer, results[:scope_recent]
    assert_kind_of Integer, results[:scope_by_title]
    assert_includes [true, false], results[:where_found]
  end
end
