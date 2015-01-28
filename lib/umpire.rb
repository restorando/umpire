require "yajl/json_gem"
require "librato/metrics"
require "excon"

require "umpire/config"
require "umpire/exceptions"
require "umpire/log"
require "umpire/aggregators"
require "umpire/instruments"

module Umpire
  autoload :Graphite, "umpire/graphite"
  autoload :InfluxDB, "umpire/influxdb"
  autoload :LibratoMetrics, "umpire/librato_metrics"
end
