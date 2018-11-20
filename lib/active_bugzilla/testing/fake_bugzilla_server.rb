require "erb"
require "yaml"
require "socket"
require "xmlrpc/server"
require "webrick" # preload here so it isn't slow in spec
require "active_support/core_ext/array/extract_options"

class FakeBugzillaDataStore
  attr_reader :data_dir, :actions

  def initialize(data_dir)
    @data_dir = data_dir

    @actions = Dir["#{data_dir}/*"].each_with_object({}) do |file, action_map|
                 key             = File.basename(file, ".*")
                 action_map[key] = YAML.load_file(file)
               end
  end
end

# A singleton server to be used in testing.  Provides a DSL for defining stub
# actions/responses, along with param validation.
#
# See FakeBugzillaServer::start_with for more info on defining a server.
class FakeBugzillaServer
  DEFAULT_HOST = "127.0.0.1".freeze

  def self.start(data_dir, host = nil, port = nil)
    setup_server(host, port)
    @data_store = FakeBugzillaDataStore.new(data_dir)
    add_handlers
    @bugzilla.serve
  end

  # Start a server, and define proper actions via a block.
  #
  #   FakeBugzillaServer.start_with do
  #     action("one") { { "body" => "1" } }
  #     action("two") { { "body" => "2" } }
  #   end
  #
  # The actions are instance_eval'd, so to properly pass variables defined
  # outside of the block, the options hash of this method will define those and
  # make them available inside the actions.
  #
  #   method_response_1 = { "body" => "1" }
  #   FakeBugzillaServer.start_with :method_response_1 => method_response_1 do
  #     action("one") { method_response_1 }
  #     action("two") { { "body" => "2" } }
  #   end
  #
  # See FakeBugzillaServer.action for more info for defining individual
  # actions.
  def self.start_with(*server_args, &block)
    @local_vars = server_args.extract_options!
    setup_server(*server_args)
    instance_eval(&block) if block_given?
    @bugzilla.serve
  end

  def self.stop
    return unless @bugzilla
    @bugzilla.shutdown
    @bugzilla, @server_port = nil
  end

  # Defines a handler for the server, using a FakeBugzillaServerResponse
  # instance for the response block.
  #
  # See FakeBugzillaServerResponse for more info the the action DSL
  def self.action(action_key, &response_block)
    responder = FakeBugzillaServerResponse.new(@local_vars, &response_block).responder
    @bugzilla.add_handler(action_key, &responder)
  end

  def self.add_handlers
    @data_store.actions.each_key do |action|
      @bugzilla.add_handler(action) do |params|
        if (action_data = @data_store.actions[action])
          matched_action = action_data["valid_requests"].detect do |req|
                             req["request_params"] == params
                           end || {}

          matched_action["response"] || not_found(action, action_data, params)
        end
      end
    end
  end

  # Defines the server (@bugzilla) instance variable.
  #
  # See XMLRPC::ThreadServer below for more info on the specific server class
  # implementation
  def self.setup_server(host = nil, port = nil)
    @server_host = host || server_host
    @server_port = port || server_port
    @bugzilla    = XMLRPC::ThreadServer.new(server_port, server_host, 1, File::NULL)
  end

  def self.server_port
    @server_port ||= TCPServer.open(server_host, 0) { |sock| sock.addr[1] }
    @server_port
  end

  def self.server_host
    @server_host ||= DEFAULT_HOST
  end

  def self.not_found(action, action_data = nil, params = nil)
    error_message = action_data["error_message"] if action_data
    if error_message
      error_binding = binding.dup
      error_binding.local_variable_set(:params, params)
      error_message = ERB.new(error_message, nil, "-").result(error_binding)
    else
      error_message = "Method #{action.inspect} missing or invalid params!"
    end
    raise XMLRPC::FaultException.new(1, error_message)
  end
end

# Based off the Hub::LocalServer helper class
#
#   https://github.com/github/hub/blob/abda01df/features/support/local_server.rb#L64
#
# This is a helper class for defining actions on the FakeBugzillaServer, which
# allows for a DSL for validating mock actions.  This allows validating the
# params passed match specific values, or are not included at all, in to ensure
# other portions of the client code is working correctly.
#
# Example:
#
#   FakeBugzillaServer.start_with do
#     action "Foo.foo" do
#       assert_bugzilla_auth "username", "password"
#       assert_parms "foo" => "foo"
#                    "bar" => :no
#
#       # response
#       { "foo" => "foo" }
#     end
#
#     action "Foo.bar" do
#       halt "Only 'foo' actions are acceptable here..."
#     end
#   end
class FakeBugzillaServerResponse
  attr_reader :params

  def initialize(local_vars, &response_block)
    @response_block = response_block

    # Allow passing variables and treat them as instance methods
    local_vars.each do |method, val|
      define_singleton_method(method) { val }
    end
  end

  # :nodoc:
  #
  # Builds the Proc that is used by FakeBugzillaServer to define a
  # `add_handler` method.
  #
  # Sets the `@params` that would be passed into the `add_handler` to the
  # instance variable, so it can easily be accessed by the DSL methods without
  # needing to pass it around as method args..
  def responder
    proc do |params|
      @params = params
      instance_eval(&@response_block)
    end
  end

  # Checks the values of individual params.  Works in two modes:
  #
  # Equivalency check (checks the param is equal):
  #
  #   assert_params "foo" => "foo"
  #
  #
  # Non-existence check (checks the param do not exist):
  #
  #   assert_params "foo" => :no
  #
  #
  # Both modes can be mixed and matched in a single call
  #
  #   assert_params "foo" => "foo"
  #                 "bar" => :no
  #
  #
  # Invalid requests will be raised if these values do not match as expected,
  # causing an error on the client.
  def assert_params(expected)
    expected.each do |key, value|
      if value && params.key?(key.to_s) == :no
        error_vals = {
          :key   => key.inspect,
          :value => params[key].inspect
        }
        error_msg = "expected %{key} not to be passed; got %{value}"
        halt(error_msg % error_vals)
      elsif params[key] != value
        error_vals = {
          :key      => key.inspect,
          :expected => value.inspect,
          :actual   => params[key].inspect
        }
        error_msg = "expected %{key} to be %{expected}; got %{actual}"
        halt(error_msg % error_vals)
      end
    end
  end

  # Checks the value of "Bugzilla_login" and "Bugzilla_password" are the
  # correct `username` and `password` values respectively.  An error is thrown
  # if either of the params don't match.
  def assert_bugzilla_auth(username, password)
    if params["Bugzilla_login"] != username
      error_vals = {
        :expected => username.inspect,
        :actual   => params["Bugzilla_login"].inspect
      }
      error_msg = "expected login to be %{expected}, but was %{actual}"
      halt(error_msg % error_vals)
    elsif params["Bugzilla_password"] != password
      error_vals = {
        :expected => password.inspect,
        :actual   => params["Bugzilla_password"].inspect
      }
      error_msg = "expected to be password to be %{expected}, but was %{actual}"
      halt(error_msg % error_vals)
    end
  end

  # Raise an error with the given message that the XMLRPC client will process
  # properly.
  def halt(msg)
    raise XMLRPC::FaultException.new(1, msg)
  end
end

# Wrapper class around XMLRPC::Server to run it in a thread
#
#   xmlrpc_server = XMLRPC::ThreadServer.new "127.0.0.1", 12345
#   xmlrpc_server.add_handler("foo") { "foo" }
#   xmlrpc_server.start
#
#   some_xmlrpc_client.call("foo")
#   # => "foo"
#
#   xmlrpc_server.stop
#
# The `XMLRPC::Server` uses a `WEBrick::HTTPServer` to handle it's requests,
# but it is indended to be the only thing run in the process.
#
# This class overwrites the `serve` and `shutdown methods in that class to run
# them in a Thread, but also remove the logging.  The `@config[:AccessLog]` is
# updated in the `serve` method just so we can retain the entire `initialize`
# method from `XMLRPC::Server` class.
#
module XMLRPC
  class ThreadServer < Server
    def serve
      @server.config[:AccessLog] = []
      @server_thread = Thread.new { @server.start }

      # HACK:  There is a race condition with starting WEBrick and shutting
      # it down in rapid succession, causing a deadlock.  This was fixed the
      # properly in Ruby 2.5:
      #
      #   https://bugs.ruby-lang.org/issues/4841
      #   https://github.com/ruby/ruby/commit/22474d8f
      #
      # But since we can't rely on this being there for many versions of ruby,
      # and doing this the right way with some kind of Mutex/ConditionVariable
      # would require a lot more monkey patching, so the `until` approach is
      # the easiest way to handle a work around
      sleep 0.001 until @server.status == :Running
    end

    def shutdown
      @server.shutdown
      @server_thread.join
    end
  end
end
