require 'uri'

module Umpire
  module Graphite
    extend self

    def get_values_for_range(metric, range, options = {})
      begin
        json = Excon.get(url(Config.graphite_url, metric, range), :expects => [200]).body
        data = JSON.parse(json)
        data.empty? ? raise(MetricNotFound) : data.flat_map { |metric| metric["datapoints"] }.map(&:first).compact
      rescue Excon::Errors::Error => e
        raise MetricServiceRequestFailed, e.message
      end
    end

    def compose_values_for_range(function, metrics, range, opts = {})
      raise UnsupportedBackendOperation, "#{self} doesn't support metrics composition"
    end

    def url(graphite_url, metric, range)
      URI.encode(URI.decode("#{graphite_url}/render/?target=#{metric}&format=json&from=-#{range}s"))
    end
  end
end
