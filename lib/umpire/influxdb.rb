require 'uri'
require 'influxdb'

module Umpire
  module InfluxDB
    extend self

    def get_values_for_range(metric, range, options)
      results = client.query(%{select value from #{metric.inspect} where time > now() - #{range}s})
      results[metric].map { |entry|  entry['value'] }
    rescue ::InfluxDB::Error => e
      raise MetricServiceRequestFailed, e.message
    end

    def compose_values_for_range(function, metrics, range, opts = {})
      raise UnsupportedBackendOperation, "#{self} doesn't support metrics composition"
    end

    private

    def client
      return @client if @client

      url = URI(Config.influxdb_url)

      options = { }
      options[:use_ssl]  = url.scheme == "https"
      options[:host]     = url.host if url.host
      options[:port]     = url.port if url.port
      options[:username] = url.user if url.user
      options[:password] = url.password if url.password
      dbname = url.path.sub(%r{/(db/)?}, "") # Remove leading slash and/or /db

      @client = ::InfluxDB::Client.new(dbname, options)
    end

  end
end
