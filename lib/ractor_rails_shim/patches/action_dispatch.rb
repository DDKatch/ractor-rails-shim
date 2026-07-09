# frozen_string_literal: true

# Patches for ActionDispatch: ExceptionWrapper (reads @@rescue_responses
# directly), and Request.parameter_parsers.

module RactorRailsShim
  # ActionDispatch + Mime constants that need to be made shareable.
  SHAREABLE_CONSTANTS.concat([
    "ActionDispatch::FileHandler::PRECOMPRESSED",
    "ActionDispatch::SSL::PERMANENT_REDIRECT_REQUEST_METHODS",
    "ActionDispatch::HostAuthorization::VALID_IP_HOSTNAME",
    "ActionDispatch::HostAuthorization::ALLOWED_HOSTS_IN_DEVELOPMENT",
    "ActionDispatch::Request::HTTP_METHODS",
    "ActionDispatch::Request::HTTP_METHOD_LOOKUP",
    "Mime::SET",
    "Mime::EXTENSION_LOOKUP",
    "Mime::LOOKUP",
    "Mime::Type::TRAILING_STAR_REGEXP",
    "Mime::Type::PARAMETER_SEPARATOR_REGEXP",
    "Mime::Type::ACCEPT_HEADER_REGEXP",
    "Mime::ALL",
    "ActionDispatch::Response::NullContentTypeHeader",
    "ActionDispatch::Response::NO_CONTENT_CODES",
    "ActionDispatch::Response::RackBody::BODY_METHODS",
    "ActionDispatch::Response::Buffer::BODY_METHODS",
  ])

  class << self
    # Patch ActionDispatch::ExceptionWrapper instance methods that read
    # @@rescue_responses / @@rescue_templates class variables directly
    # (bypassing the mattr_accessor reader the shim already reroutes through
    # IES). Workers can't read class vars; route through the class method.
    def _install_exception_wrapper_patch
      return if @exception_wrapper_patched
      @exception_wrapper_patched = true
      _register_patch :exception_wrapper, "8.1"
      return unless defined?(::ActionDispatch::ExceptionWrapper)
      ::ActionDispatch::ExceptionWrapper.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def rescue_template
          self.class.rescue_templates[exception_class_name]
        end
        def status_code
          ActionDispatch::Response.rack_status_code(self.class.rescue_responses[exception_class_name])
        end
        def rescue_response?
          self.class.rescue_responses.key?(exception.class.name)
        end
      RUBY
      # Also patch the class method (status_code_for_exception) that reads
      # @@rescue_responses directly — called by ActionController::Instrumentation
      # at request time. Route through the mattr reader (which the shim already
      # reroutes through IES).
      ::ActionDispatch::ExceptionWrapper.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def status_code_for_exception(class_name)
          ActionDispatch::Response.rack_status_code(rescue_responses[class_name])
        end
      RUBY
    end

    # Patch ActionDispatch::Request.parameter_parsers (singleton attr_reader
    # backed by @parameter_parsers) to not read the class ivar from a worker
    # Ractor. The value is a Hash of MIME-type → parser (lambdas). Route
    # through IES; workers read the shareable fallback (the boot-time parsers,
    # made shareable). Read per-request during parameter parsing.
    def _install_request_parameter_parsers_patch
      return if @request_param_parsers_patched
      @request_param_parsers_patched = true
      _register_patch :request_parameter_parsers, "8.1"
      return unless defined?(::ActionDispatch::Request)
      req = ::ActionDispatch::Request
      pp_key = :ractor_rails_shim_request_parameter_parsers
      pp_key_str = pp_key.inspect
      req.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def parameter_parsers
          v = ActiveSupport::IsolatedExecutionState[#{pp_key_str}]
          return v unless v.nil?
          if Ractor.main? && instance_variable_defined?(:@parameter_parsers)
            v = @parameter_parsers
            ActiveSupport::IsolatedExecutionState[#{pp_key_str}] = v
            v
          else
            RactorRailsShim::SHAREABLE_FALLBACK[#{pp_key_str}] || ActionDispatch::Request::DEFAULT_PARSERS
          end
        end
      RUBY
      CLASS_ATTRIBUTES << ["ActionDispatch::Request", :parameter_parsers, pp_key, nil]
    end
  end
end
