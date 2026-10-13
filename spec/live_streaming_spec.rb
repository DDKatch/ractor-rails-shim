# frozen_string_literal: true

require "minitest/autorun"

# Specs for the ActionController::Live worker-streaming patch (core.rb
# `_install_live_streaming_patch`).
#
# Workers run the streaming action INLINE: `new_controller_thread` yields on
# the request thread instead of hopping to the lazy class-ivar pool (whose
# write is forbidden in non-main Ractors, and whose thread hop deadlocks
# `await_commit` when the pooled thread dies before committing). Main keeps
# the upstream pool-thread behavior verbatim.
#
# The shim bundle intentionally does NOT depend on actionpack (the runtime
# gem dependency stays activesupport-only), so these specs self-skip unless
# ActionController::Live happens to be loadable; the worker branch is
# exercised by the kino (blob proxy dispatch, row 127).
begin
  require "action_controller"
rescue LoadError
  nil
end

if defined?(::ActionController::Live)
  class LiveStreamingSpec < Minitest::Spec
    before { RactorRailsShim::Patches::LiveStreaming.install }

    it "keeps the upstream pool-thread behavior on main" do
      # Main: new_controller_thread must run the block on a DIFFERENT
      # thread (upstream semantics verbatim).
      main_thread = Thread.current
      block_thread = nil
      controller = Object.new.extend(ActionController::Live)
      controller.__send__(:new_controller_thread) { block_thread = Thread.current }
      refute_nil block_thread
      refute_same main_thread, block_thread
    end
  end
end
