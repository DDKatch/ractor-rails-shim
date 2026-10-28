# frozen_string_literal: true

module RactorRailsShim
  # SolidQueue worker-side enqueue (RAILS_FEATURES.md row 110 —
  # `perform_later` from a worker Ractor) hits two shareability walls:
  #
  # 1. `SolidQueue::Batch.migrated?` lazily memoizes a CLASS ivar
  #    (`@migrated ||=` on the frozen engine-model class). A worker's first
  #    enqueue raises Ractor::IsolationError on that write.
  #    Fix: pre-warm the memo in MAIN at prepare time (the value is a
  #    boolean — natively shareable — so post-freeze the worker read
  #    short-circuits the `||=` and no write happens).
  #
  # 2. `SolidQueue::Execution::JobAttributes.assumes_attributes_from_job`
  #    registers `before_create -> { assume_attributes_from_job }` — a
  #    BLOCK callback (un-shareable Proc) that copies queue_name/priority/
  #    scheduled_at from the job row onto the execution row before INSERT.
  #    SymbolicTransport fail-safe skips block filters, so the copy never
  #    runs in workers and the INSERT dies with PG::NotNullViolation
  #    (null queue_name in solid_queue_scheduled_executions).
  #    Fix (the ARCHITECTURE.md "recipe for ANY callback"): the block's
  #    effect reduces to a call to the REAL instance method
  #    `assume_attributes_from_job` — so redefine the macro to register the
  #    callback as a SYMBOLIC filter (`before_create :assume_attributes_from_job`)
  #    and re-apply it for the execution models that already declared it
  #    block-style at gem load. The symbolic entry is captured by
  #    CallbackCapture (declared during the prepare pipeline, BEFORE
  #    freeze_declared_callbacks!) and replayed in workers via the real def.
  #    In MAIN the redeclaration adds a second (idempotent) pass of the same
  #    attribute copies.
  module Patches
    module SolidQueuePatch
      module_function

      # Lazily-memoized class ivars that must exist pre-freeze for
      # worker-side enqueue. Keep minimal: only what the enqueue path reads.
      PREWARM_METHODS = Ractor.make_shareable([
        ["SolidQueue::Batch", :migrated?]
      ].freeze)

      # The execution models that declared `assumes_attributes_from_job
      # :scheduled_at` block-style at gem load (verified in solid_queue
      # 1.7: scheduled_execution.rb, ready_execution.rb, blocked_execution.rb).
      ASSUMING_EXECUTION_MODELS = Ractor.make_shareable(%w[
        ScheduledExecution ReadyExecution BlockedExecution
      ].freeze)

      def apply!
        return true if @applied
        @applied = true
        prewarm_batch_migrated!
        patch_execution_assumption!
        true
      end

      def prewarm_batch_migrated!
        return true unless defined?(::SolidQueue)
        PREWARM_METHODS.each do |class_name, method|
          klass = begin
            ::Object.const_get(class_name)
          rescue NameError
            nil
          end
          next unless klass.is_a?(::Class)
          RactorRailsShim.__send__(:_swallow, "prewarm solid_queue #{class_name}##{method}") do
            klass.__send__(method)
          end
        end
        true
      end

      def patch_execution_assumption!
        return true unless defined?(::SolidQueue::Execution::JobAttributes::ClassMethods)
        class_methods = ::SolidQueue::Execution::JobAttributes::ClassMethods
        class_methods.module_eval <<~RUBY, __FILE__, __LINE__ + 1
          # Worker-safe redefinition: string-eval'd (no captured binding), and
          # registers the callback as a SYMBOLIC filter so CallbackCapture
          # records it and SymbolicTransport replays it in workers. The body
          # mirrors the upstream block callback (which just called the
          # private #assume_attributes_from_job instance method).
          def assumes_attributes_from_job(*attribute_names)
            self.assumable_attributes_from_job |= attribute_names
            before_create :assume_attributes_from_job
          end
        RUBY
        # Re-apply for models that already declared it block-style: the |=
        # is a no-op; the redeclaration registers the symbolic before_create.
        ASSUMING_EXECUTION_MODELS.each do |model_name|
          klass = begin
            ::SolidQueue.const_get(model_name)
          rescue NameError
            nil
          end
          redeclare_symbolic_assumption!(klass)
        end
        true
      end

      # NOTE: do NOT hardcode the attr list — each execution model declares
      # its own (ReadyExecution none (default queue_name/priority),
      # ScheduledExecution :scheduled_at, BlockedExecution :concurrency_key).
      # Re-apply with each model's CURRENT assumable list (the |= makes the
      # redeclaration idempotent data-wise; the callback goes symbolic).
      def redeclare_symbolic_assumption!(klass)
        return false unless klass.is_a?(::Class)
        current = klass.assumable_attributes_from_job
        current = current.map(&:to_sym) if current
        RactorRailsShim.__send__(:_swallow, "redeclare solid_queue #{klass}#assumes_attributes_from_job") do
          klass.assumes_attributes_from_job(*(current || []))
        end
        true
      end
    end
  end

  def self._prewarm_solid_queue! = Patches::SolidQueuePatch.apply!
end
