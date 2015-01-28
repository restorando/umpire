require "puma"
require "sinatra/base"
require 'rack/ssl'
require 'rack-timeout'
require 'securerandom'

require "umpire"

module Umpire
  class Web < Sinatra::Base
    enable :dump_errors
    disable :show_exceptions

    use Rack::SSL if Config.force_https?
    use Rack::Timeout unless test?
    Rack::Timeout.timeout = 29

    configure do
      set :server, :puma
    end

    before do
      content_type :json
      grab_request_id
    end

    after do
      Thread.current[:scope] = nil
      Thread.current[:request_id] = nil
      Umpire::Log.add_global_context(:request_id => nil)
    end

    helpers do
      def log(data, &blk)
        self.class.log(data, &blk)
      end

      def protected!
        unless authorized?
          response["WWW-Authenticate"] = %(Basic realm="Restricted Area")
          throw(:halt, [401, JSON.dump({"error" => "not authorized"}) + "\n"])
        end
      end

      def authorized?
        @auth ||=  Rack::Auth::Basic::Request.new(request.env)
        if @auth.provided? && @auth.basic? && @auth.credentials
          if Thread.current[:scope] = Config.find_scope_by_key(@auth.credentials[1])
            true
          end
        end
      end

      def request_id
        Thread.current[:request_id]
      end

      def grab_request_id
        Thread.current[:request_id] = request.env["HTTP_HEROKU_REQUEST_ID"] || request.env["HTTP_X_REQUEST_ID"] || SecureRandom.hex(16)
        Umpire::Log.add_global_context(:request_id => Thread.current[:request_id])
      end

      def valid?(params)
        errors = []
        if !params["metric"]
          errors.push("metric is required")
        end
        if !params["range"]
          errors.push("range is required")
        end
        if !params["min"] && !params["max"]
          errors.push("one of min or max are required")
        end
        if params["empty_ok"] && !%w[yes y 1 true].include?(params["empty_ok"].to_s.downcase)
          errors.push("empty_ok must be one of yes/y/1/true")
        end
        errors
      end

      def fetch_points(params)
        metrics = params["metric"].split(",")
        range   = (params["range"] && params["range"].to_i)
        backend = metrics_backend(params["backend"])
        options = extract_options(params)

        if compose = params["compose"]
          backend.compose_values_for_range(compose, metrics, range, options)
        else
          raise MetricNotComposite, "multiple metrics without a compose function" if metrics.size > 1
          backend.get_values_for_range(metrics.first, range, options)
        end
      end

      def metrics_backend(backend)
        case backend
        when "librato"
          LibratoMetrics
        when "influxdb"
          InfluxDB
        else
          Graphite
        end
      end

      def extract_options(params)
        %w[source from resolution].each_with_object({}) do |key, opts|
          opts[key.to_sym] = params[key] if params[key]
        end
      end

      def create_aggregator(aggregation_method)
        case aggregation_method
        when "avg"
          Aggregator::Avg.new
        when "sum"
          Aggregator::Sum.new
        when "min"
          Aggregator::Min.new
        when "max"
          Aggregator::Max.new
        else
          Aggregator::Avg.new
        end
      end
    end

    get "/check" do
      protected!

      param_errors = valid?(params)
      unless param_errors.empty?
        log(action: "check", at: "invalid_params")
        halt 400, JSON.dump({"error" => param_errors.join(", "), "request_id" => request_id}) + "\n"
      end

      min = (params["min"] && params["min"].to_f)
      max = (params["max"] && params["max"].to_f)

      empty_ok = !!params["empty_ok"]

      aggregator = create_aggregator(params["aggregate"])

      backend = params["backend"] || "graphite"

      Umpire::Log.context(action: "check", metric: params["metric"], backend: backend, source: params["source"]) do
        begin
          points = fetch_points(params)
          if points.empty?
            if empty_ok
              log(at: "no_points_empty_ok")
            else
              status 404
              log(at: "no_points")
            end
            JSON.dump({"error" => "no values for metric in range", "request_id" => request_id}) + "\n"
          else
            value = aggregator.aggregate(points)
            if ((min && (value < min)) || (max && (value > max)))
              log(at: "out_of_range", min: min, max: max, value: value, num_points: points.count)
              status 500
            else
              log(at: "ok", min: min, max: max, value: value, num_points: points.count)
              status 200
            end
            JSON.dump({"value" => value, "min" => min, "max" => max, "num_points" => points.count, "request_id" => request_id}) + "\n"
          end
        rescue MetricNotComposite => e
          log(at: "metric_not_composite", error: e.message)
          halt 400, JSON.dump("error" => e.message, "request_id" => request_id) + "\n"
        rescue MetricNotFound
          log(at: "metric_not_found")
          halt 404, JSON.dump({"error" => "metric not found", "request_id" => request_id}) + "\n"
        rescue MetricServiceRequestFailed => e
          log(at: "metric_service_request_failed", message: e.message)
          halt 503, JSON.dump({"error" => "connecting to backend metrics service failed with error '#{e.message}'", "request_id" => request_id}) + "\n"
        end
      end
    end

    get "/health" do
      log(action: "health")
      JSON.dump({"health" => "ok"}) + "\n"
    end

    get "/*" do
      log(action: "not_found")
      halt 404, JSON.dump({"error" => "not found"}) + "\n"
    end

    error do
      e = env["sinatra.error"]
      log(at: "internal_error", "class" => e.class, message: e.message)
      status 500
      JSON.dump({"error" => "internal server error", "request_id" => request_id}) + "\n"
    end

    def self.start
      log(fn: "start", at: "install_trap")
      Signal.trap("TERM") do
        log(fn: "trap")
        stop!
        log(fn: "trap", at: "exit", status: 0)
        Kernel.exit!(0)
      end

      log(fn: "start", at: "run_server")
      run!
    end

    def self.log(data, &blk)
      data.delete(:level)
      Log.log({ns: "web", scope: Thread.current[:scope], request_id: Thread.current[:request_id]}.merge(data), &blk)
    end
  end
end
