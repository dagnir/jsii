require 'open3'
require 'logger'
require 'json'
require_relative 'errors'
require_relative 'base'
require_relative 'enum'

TOKEN_DATE = '$jsii.date'
TOKEN_REF  = '$jsii.byref'
TOKEN_ENUM = '$jsii.enum'

module Aws
  module Jsii
    # Represents the jsii-runtime
    class Runtime

      # singleton instance of jsii runtime
      def self.instance
        @@instance ||= Runtime.new
      end

      def initialize(debug = nil)
        @logger = Logger.new(STDERR)

        if (debug.nil?)
          debug = ENV['JSII_DEBUG'] == '1'
        end

        @debug = debug
        @logger.level = debug ? Logger::DEBUG : Logger::INFO

        runtime_js = File.join(File.dirname(__FILE__), '..', '..', 'resources', 'jsii-runtime.js')
        @logger.debug("jsii-runtime at: #{runtime_js}")
        env = {}
        env['JSII_DEBUG'] = '1' if @debug
        @stdin, @stdout, wait_thr = Open3.popen2(env, 'node', runtime_js)

        @logger.debug("jsii-runtime started on pid #{wait_thr.pid}")

        # ensure version compat.
        handshake

        at_exit { close }

        @fqn_map = { }
      end

      def close
        @logger.debug('closing jsii-runtime child-process streams...')
        @stdin.close
        @stdout.close
      end

      def map_fqn(fqn, cls)
        @fqn_map[fqn] = cls
      end

      def self.define_api(api)
        define_method(api) do |**opts|
          request_response(api: api, **opts)
        end
      end

      define_api :load
      define_api :create
      define_api :del
      define_api :get
      define_api :sget
      define_api :set
      define_api :sset
      define_api :invoke
      define_api :sinvoke
      define_api :begin
      define_api :end
      define_api :callbacks
      define_api :complete
      define_api :naming
      define_api :stats

      def on_callback(&blk)
        @callback_handler = blk
      end

      def register_object(objref, obj)
        @objects ||= {}
        ref = objref[TOKEN_REF]
        raise "objref #{ref} already registered" if not @objects[ref].nil?
        @objects[ref] = obj
        obj._jsii_objref = objref

        ref
      end

      def to_jsii(x)
        if x.nil?
          return nil
        end

        # array
        if x.kind_of?(Array)
          return x.map { |e| self.to_jsii(e) }.to_a
        end

        # hash
        if x.kind_of?(Hash)
          return x.map { |k,v| [k, self.to_jsii(v)] }.to_h
        end

        # date
        if x.kind_of?(DateTime)
          return { TOKEN_DATE => x.iso8601 }
        end

        # object reference
        if x.kind_of?(JsiiObject)
          return x._jsii_objref
        end

        if x.kind_of?(JsiiEnum)
          return { TOKEN_ENUM => x.fqn }
        end

        # primitive
        return x
      end

      def from_jsii(x)
        if x.kind_of?(Hash)
          if not x[TOKEN_DATE].nil?
            return DateTime.parse(x[TOKEN_DATE])
          end

          if not x[TOKEN_REF].nil?
            return find_create_objref(x)
          end

          if not x[TOKEN_ENUM].nil?
            return resolve_ruby_enum(x)
          end

          return x.map { |k,v| [ k, self.from_jsii(v) ] }.to_h
        end

        if (x.kind_of?(Array))
          return x.map { |v| from_jsii(v) }.to_a
        end

        return x
      end

      def process_callback(callback)
        result = nil
        err = nil

        begin
          if @callback_handler
            result = @callback_handler.call(callback)
          else
            if callback['invoke']
              result = process_invoke_callback(callback['invoke'])
            elsif callback['get']
              result = process_get_callback(callback['get'])
            elsif callback['set']
              result = process_set_callback(callback['set'])
            end
          end
        rescue StandardError => e
          err = e.full_message
        end

        return {
          cbid: callback['cbid'],
          err: to_jsii(err),
          result: to_jsii(result)
        }
      end

      private

      def process_invoke_callback(invoke)
        objref = invoke['objref']
        method = invoke['method']
        args = invoke['args']

        obj = find_create_objref(objref)
        ruby_method = obj._jsii_lookup_method(method)
        return ruby_method.call(*args)
      end

      def find_create_objref(objref)
        @objects ||= {}

        ref = objref[TOKEN_REF]

        obj = @objects[ref]

        # object created in javascript land, so we need to dynamically create
        # an instanc for it here based on it's ruby type
        if obj.nil?
          cls = resolve_ruby_type(objref)
          obj = cls.allocate
          register_object(objref, obj)
        end

        return obj
      end

      def request_response(req)
        req_s = JSON.generate(req.delete_if { |_, v| v.nil? })

        @logger.debug("> #{req_s}")
        @stdin.puts(req_s)

        resp = read_next_response
        @logger.debug("< #{JSON.generate(resp)}")

        return process_error(resp) if resp['error']

        if resp['callback']
          complete = process_callback(resp['callback'])
          return request_response(complete: complete)
        end

        # if resp["ok"] is nil, it means 'undefined' (or void), so we just return it as-is
        resp['ok']
      end

      def read_next_response
        line = @stdout.readline
        @logger.debug("line: #{line}")
        JSON.parse(line)
      end

      def handshake
        hello = read_next_response
        version = hello['hello']

        expected_version = File.read(File.join(File.dirname(__FILE__), '..', '..', 'version.txt')).strip
        expected_version_string = "jsii-runtime@#{expected_version}"

        if version != expected_version_string
          raise JsiiError, "Invalid jsii-runtime handshake version '#{version}'. Expected: '#{expected_version_string}'"
        end
      end

      def process_error(resp)
        message = resp['error']
        stack = resp['stack']
        message += "\n#{stack}" if stack
        raise JsiiError, message
      end

      def resolve_ruby_type(objref)
        ref = objref[TOKEN_REF]
        fqn = ref.split('@')[0]

        cls = @fqn_map[fqn]
        raise "Unable to resolve Ruby type for objref #{ref}" if cls.nil?
        return cls
      end

      def resolve_ruby_enum(enum)
        fqn = enum[TOKEN_ENUM]
        ref = @fqn_map[fqn]
        raise "Unable to resolve enum reference for FQN #{fqn}" if ref.nil?
        return ref
      end
    end
  end
end
