# frozen_string_literal: true

# TDD specs for DependentAssociationTransport — the transport that replays a
# model's `dependent:` association cascades on the `:destroy` kind. This is the
# reference implementation of a transport for a LAMBDA callback that reduces to
# a declarative spec (see ARCHITECTURE.md §5c Strategy B): the dependent lambda
# is unshareable, but (class => [{name, type, macro}]) is shareable, and replay
# re-drives `record.association(name).handle_dependency`.
#
# Run: bundle exec ruby -Ilib -Ispec spec/callbacks/dependent_association_transport_spec.rb

require "minitest/autorun"
require_relative "../../lib/ractor_rails_shim/callbacks/dependent_association_transport"

class DependentAssociationTransportSpec < Minitest::Spec
  # Fake association object: records handle_dependency calls.
  class FakeAssoc
    attr_reader :name, :handled
    def initialize(name); @name = name; @handled = 0; end
    def handle_dependency; @handled += 1; :handled; end
  end

  # Fake record: returns associations by name from an injected map, and reports
  # its class name (the key the transport looks up in the source).
  class FakeRecord
    attr_reader :class_name, :assocs
    def initialize(class_name, assocs)
      @class_name = class_name
      @assocs = assocs
    end
    def class
      Class.new { define_method(:name) { @n } }.tap { |c| c.name rescue nil }
      # Minimal: expose the class NAME via a singleton, since transport uses
      # context.class.name.
    end
    # The transport uses context.class.name — provide it on the singleton class.
    def self.build(class_name, assocs)
      rec = new(class_name, assocs)
      rec.singleton_class.define_method(:class) do
        klass = Object.new
        klass.singleton_class.define_method(:name) { class_name }
        klass
      end
      rec
    end
    def association(name)
      @assocs[name]
    end
  end

  it "applies only to :destroy" do
    t = RactorRailsShim::Callbacks::DependentAssociationTransport.new(source: {})
    assert t.applies_to?(:destroy)
    refute t.applies_to?(:save)
    refute t.applies_to?(:process_action)
  end

  it "calls handle_dependency on each dependent association of the record's class" do
    comments_assoc = FakeAssoc.new(:comments)
    posts_assoc = FakeAssoc.new(:posts)
    source = {
      "User" => [
        { name: :comments, type: :destroy, macro: :has_many },
        { name: :posts, type: :destroy, macro: :has_many }
      ]
    }
    record = FakeRecord.build("User", { comments: comments_assoc, posts: posts_assoc })
    t = RactorRailsShim::Callbacks::DependentAssociationTransport.new(source: source)
    t.before(record, :destroy)
    assert_equal 1, comments_assoc.handled
    assert_equal 1, posts_assoc.handled
  end

  it "does nothing when the record's class has no dependent associations" do
    assoc = FakeAssoc.new(:comments)
    source = { "User" => [{ name: :comments, type: :destroy, macro: :has_many }] }
    record = FakeRecord.build("Post", { comments: assoc }) # Post not in source
    t = RactorRailsShim::Callbacks::DependentAssociationTransport.new(source: source)
    t.before(record, :destroy)
    assert_equal 0, assoc.handled
  end

  it "after-phase is a no-op (dependent cascades are before_destroy)" do
    t = RactorRailsShim::Callbacks::DependentAssociationTransport.new(source: {})
    assert_nil t.after(FakeRecord.build("X", {}), :destroy)
  end

  it "is a no-op when the source has no entry for the class name" do
    record = FakeRecord.build("Comment", {})
    t = RactorRailsShim::Callbacks::DependentAssociationTransport.new(source: {})
    assert_nil t.before(record, :destroy)
  end
end