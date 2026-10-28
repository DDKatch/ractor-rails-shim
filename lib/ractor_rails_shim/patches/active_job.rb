# frozen_string_literal: true

module RactorRailsShim
  # ActiveJob::Arguments constants read on every argument (de)serialization —
  # RESERVED_KEYS is an unfrozen Array of Symbols that workers read on every
  # enqueue/perform, so a worker dies with
  #   Ractor::IsolationError: can not access non-shareable objects in
  #   constant ActiveJob::Arguments::RESERVED_KEYS by non-main ractor.
  SHAREABLE_CONSTANTS.concat([
    "ActiveJob::Arguments::RESERVED_KEYS"
  ])

  # ActiveJob::Serializers keeps its serializer registry in TWO class ivars:
  #   @serializers       → a Set of singleton serializer instances
  #   @serializers_index → a Hash (argument class → serializer instance)
  # Argument serialization for custom objects (ActiveJob::Arguments.serialize
  # → Serializers.serialize) reads @serializers_index directly, so a worker
  # Ractor enqueuing a job with a custom-serializer argument dies with
  #   Ractor::IsolationError: can not get unshareable values from instance
  #   variables of classes/modules from non-main Ractors
  #   (@serializers_index from ActiveJob::Serializers)
  # Custom serializers are registered at boot via
  # ActiveJob::Serializers.add_serializers — a MAIN-only mutation.
  #
  # Fix: register the class with Freezers::GlobalClassIvarFreezer — at
  # prepare_for_ractors! time (after the app's initializers have registered
  # every custom serializer, and BEFORE workers spawn) the freezer runs
  # Ractor.make_shareable over each ivar value, making both the Set and the
  # Hash frozen + shareable. Ruby 4 allows non-main Ractors to READ a class
  # ivar whose value is shareable, so the upstream bodies (serialize /
  # deserialize / the serializers reader) keep working verbatim — no method
  # redefinition.
  #
  # The serializer instances themselves are stateless Singletons holding one
  # frozen @template Hash ({ "_aj_serialized" => "..." }) — shareable once
  # deep-frozen. Nothing mutates the registry after boot, so freezing is
  # side-effect-free.
  module ActiveJobSerializersPatch
    module_function

    def apply!
      return true if @patched
      @patched = true
      RactorRailsShim.__send__(:_register_patch, :active_job_serializers, "8.1")
      register_target!
    end

    # Add the freezer target. Safe to call before ActiveJob is loaded: the
    # target list holds NAME STRINGS resolved by the freezer at prepare time
    # (by then the jobs railtie has loaded ActiveJob in every real app).
    #
    # Two-phase: if ActiveJob::Serializers is already loaded, register now;
    # otherwise defer via ActiveSupport.on_load(:active_job) (the hook fires
    # when the jobs railtie loads Base — during framework boot, well before
    # prepare_for_ractors!). The hook explicitly requires the serializers
    # file because ActiveJob autoloads it lazily — an unloaded constant at
    # hook-fire time must not lose the registration.
    def register_target!
      if defined?(::ActiveJob::Serializers)
        Freezers::GlobalClassIvarFreezer.add_target("ActiveJob::Serializers")
        return true
      end
      unless defined?(ActiveSupport.on_load)
        require "active_support/lazy_load_hooks"
      end
      ActiveSupport.on_load(:active_job) do
        require "active_job/serializers" unless defined?(::ActiveJob::Serializers)
        RactorRailsShim::ActiveJobSerializersPatch.register_target!
      end
      :deferred
    end
  end

  def self._install_active_job_serializers_patch = ActiveJobSerializersPatch.apply!

  # The json gem's `JSON::Coder` instance that ActiveSupport's
  # JSONGemCoderEncoder exposes as the class CONSTANT
  # `::CODER` (encoding.rb:152) is unfrozen at load — the AR JSON coder
  # (`ActiveRecord::Coders::JSON#dump`, i.e. every `serialize :attr, coder: JSON`
  # write, including SolidQueue's job-arguments column) reads it on the
  # encode path, and a worker Ractor reading a constant whose value is not
  # shareable raises
  #   Ractor::IsolationError: can not access non-shareable objects in
  #   constant ... ::CODER by non-main ractor
  # Fix (prepare-time freeze, no method patch): `Ractor.make_shareable` the
  # constant's value in MAIN before the freeze — the coder is a simple value
  # object (a JSON::Coder wrapping a shareable block), so freezing is
  # behavior-preserving and the worker constant read becomes legal.
  module JsonCoderFreezer
    module_function

    TARGETS = Ractor.make_shareable([
      ["ActiveSupport::JSON::Encoding::JSONGemCoderEncoder", :CODER]
    ].freeze)

    def apply!
      return true if @frozen
      @frozen = true
      TARGETS.each do |const_path, const_name|
        RactorRailsShim.__send__(:_swallow, "freeze json coder #{const_path}::#{const_name}") do
          mod = const_path.split("::").inject(::Object) { |acc, n| acc.const_get(n) }
          next unless mod.const_defined?(const_name, false)
          val = mod.const_get(const_name, false)
          next if Ractor.shareable?(val)
          Ractor.make_shareable(val)
        end
      end
      true
    end
  end

  def self._freeze_json_coder_constants! = JsonCoderFreezer.apply!
end
