require 'httparty'
require 'http/exceptions'
require_relative 'json_parser'

module OandaAPI
  # List of valid subdomains clients can access.
  DOMAINS = [:live, :practice, :sandbox]

  # Provides everything needed for accessing the API.
  #
  # - Uses persistant http connections.
  # - Uses `OpenSSL::SSL::VERIFY_PEER` to always validate SSL certificates.
  # - Uses compression if enabled (see {Configuration#use_compression}).
  # - Uses request rate limiting if enabled (see {Configuration#use_request_throttling}).
  module Client
    include HTTParty

    # Used to synchronize throttling metrics
    @throttle_mutex = Mutex.new

    # Use a custom JSON parser
    parser OandaAPI::Client::JsonParser

    # Resource URI templates
    BASE_URI = {
      live:     "https://api-fxtrade.oanda.com/[API_VERSION]",
      practice: "https://api-fxpractice.oanda.com/[API_VERSION]",
      sandbox:  "http://api-sandbox.oanda.com/[API_VERSION]"
    }

    # @private
    # Camelizes keys and transforms array values into comma-delimited strings.
    #
    # @return [String] a url encoded query string.
    query_string_normalizer proc { |hash|
      Array(hash).sort_by { |key, _value| key.to_s }.map do |key, value|
        if value.nil?
          Utils.camelize(key.to_s)
        elsif value.respond_to?(:to_ary)
          serialized = URI.encode value.join(","),
                                  Regexp.new("[^#{URI::PATTERN::UNRESERVED}]")
          "#{Utils.camelize(key)}=#{serialized}"
        else
          HashConversions.to_params Utils.camelize(key) => value
        end
      end.flatten.join("&")
    }

    # Common initializations
    # @param [Hash] options Specifies overrides to default settings.
    #  Overrides for the persistent connection adapter are specified
    #  by including an :connection_adapter_options: {} hash.
    # @return [OandaAPI::Client]   
    def initialize(options={})
      super()
      load_persistent_connection_adapter options[:connection_adapter_options] || {}
    end

    # Returns an absolute URI for a resource request.
    #
    # @param [String] path the path portion of the URI.
    #
    # @return [String] a URI.
    def api_uri(path)
      uri = "#{BASE_URI[domain]}#{path}"
      uri.sub "[API_VERSION]", OandaAPI.configuration.rest_api_version
    end

    # Binds a persistent connection adapter. See documentation for the
    #  persistent_httparty gem for configuration details.
    # @param [Hash] options Specifies overrides for the connection adapter.
    #
    # @return [void]
    def load_persistent_connection_adapter(options={})
      adapter_config = {
        name:         "oanda_api",
        idle_timeout: 10,
        keep_alive:   30,
        warn_timeout: 2,
        pool_size:    OandaAPI.configuration.connection_pool_size,
      }.merge options

      Client.persistent_connection_adapter adapter_config
    end

    # @private
    # Executes an http request.
    #
    # @param [Symbol] method a request action. See {Client.map_method_to_http_verb}.
    #
    # @param [String] path the path of an Oanda resource request.
    #
    # @param [Hash] conditions optional parameters that are converted into
    #   either a query string or url form encoded parameters.
    #
    # @return [OandaAPI::ResourceBase] if the API request returns a singular
    #   resource. See {OandaAPI::Resource} for a list of resource types that
    #   can be returned.
    #
    # @return [OandaAPI::ResourceCollection] if the API request returns a
    #   collection of resources.
    #
    # @raise [OandaAPI::RequestError] if the API return code is not 2xx.
    def execute_request(method, path, conditions = {})
      response = Http::Exceptions.wrap_and_check do
        method = Client.map_method_to_http_verb(method)
        params_key = [:post, :patch, :put].include?(method) ? :body : :query
        Client.throttle_request_rate
        Client.send method,
                    api_uri(path),
                    params_key    => Utils.stringify_keys(conditions.merge(default_params)),
                    :headers      => OandaAPI.configuration.headers.merge(headers),
                    :open_timeout => OandaAPI.configuration.open_timeout,
                    :read_timeout => OandaAPI.configuration.read_timeout
      end

      handle_response response, ResourceDescriptor.new(path, method)
      rescue Http::Exceptions::HttpException => e
        raise OandaAPI::RequestError, e.message
    end

    # @private
    # Maps An API _action_ to a corresponding http verb.
    #
    # @param [Symbol] method an API action. Supported actions are:
    #  `:create`, `:close`, `:delete`, `:get`, `:update`.
    #
    # @return [Symbol] an http verb.
    def self.map_method_to_http_verb(method)
      case method
      when :create
        :post
      when :close
        :delete
      when :update
        :patch
      else
        method
      end
    end

    def self.last_request_at
      @throttle_mutex.synchronize { @last_request_at }
    end

    def self.last_request_at=(value)
      @throttle_mutex.synchronize { @last_request_at = value }
    end

    # @private
    # Limits the execution rate of consecutive requests. Specified by
    # {OandaAPI::Configuration#max_requests_per_second}. Only enforced
    # if {OandaAPI::Configuration#use_request_throttling?} is enabled.
    #
    # @return [void]
    def self.throttle_request_rate
      now = Time.now
      delta = now - (last_request_at || now)
      _throttle(delta, now) if delta < OandaAPI.configuration.min_request_interval &&
                                       OandaAPI.configuration.use_request_throttling?
      last_request_at = Time.now
    end

    # @private
    # The local time of the most recently throttled request.
    #
    # @return [Time] if any request has been throttled, the most recent time when
    #   one was temporarily suspended.
    #
    # @return [nil] if a request has never been throttled.
    def self.last_throttled_at
      @throttle_mutex.synchronize { @throttled_at }
    end

    private

    # @private
    # Sleeps for the minimal amount of time required to honour the
    # {OandaAPI::Configuration#max_requests_per_second} limit.
    #
    # @param [Float] delta The duration in seconds since the last request.
    # @param [Time] time The time that the throttle was requested.
    #
    # @return [void]
    def self._throttle(delta, time)
      @throttle_mutex.synchronize do
        @throttled_at = time
        sleep OandaAPI.configuration.min_request_interval - delta
      end
    end

    # @private
    # Formats the response from the Oanda API into a resource object.
    #
    # @param [#each_pair] response a hash-like object returned by
    #   the internal http client.
    #
    # @param [OandaAPI::Client::ResourceDescriptor] resource_descriptor metadata
    #   describing the requested resource.
    # @return [OandaAPI::ResourceBase, OandaAPI::ResourceCollection] see {#execute_request}
    def handle_response(response, resource_descriptor)
      if resource_descriptor.is_collection?
        ResourceCollection.new response, resource_descriptor
      else
        resource_descriptor.resource_klass.new response
      end
    end

    # @private
    # Enables method-chaining.
    # @return [NamespaceProxy]
    def method_missing(sym, *args)
      NamespaceProxy.new self, sym, args.first
    end
  end
end
