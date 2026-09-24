require 'active_support'
require 'active_support/core_ext/integer/time'

module ClickMan
  class Configuration
    attr_accessor :database
    attr_accessor :write_keys
    attr_accessor :filter_fragments
    attr_accessor :max_event_age
    attr_accessor :rate_limit
    attr_accessor :dedup_window
    attr_accessor :retention
    attr_accessor :rotation_lag
    attr_accessor :funnels_path
    attr_accessor :base_controller_class
    attr_accessor :destinations
    attr_accessor :ingest_url
    attr_accessor :publish_on_boot

    def initialize
      @database = nil
      @write_keys = {}
      @filter_fragments = Sanitizer::DEFAULT_FRAGMENTS.dup
      @max_event_age = 90.days
      @rate_limit = { per_second: 20, burst: 100 }
      @dedup_window = 7.days
      @retention = nil
      @rotation_lag = 2.minutes
      @funnels_path = nil
      @base_controller_class = nil
      @destinations = []
      @ingest_url = ENV.fetch('CLICKMAN_INGEST_URL', 'http://127.0.0.1:4130')
      @publish_on_boot = true
    end

    def sanitizer
      Sanitizer.new(filter_fragments)
    end

    def validate!
      unless rate_limit[:per_second].to_f.positive? && rate_limit[:burst].to_f >= 1
        raise ConfigurationError, 'rate_limit needs a positive per_second and a burst of at least 1'
      end
      raise ConfigurationError, 'max_event_age must be positive' unless max_event_age.to_i.positive?
      raise ConfigurationError, 'dedup_window must be positive' unless dedup_window.to_i.positive?
      raise ConfigurationError, 'retention must be positive or nil' if retention && !retention.to_i.positive?

      validate_destinations!
      self
    end

    private

      def validate_destinations!
        destinations.each do |destination|
          raise ConfigurationError, "#{destination.inspect} is not a ClickMan::Destination" unless destination.is_a?(Destination)
        end

        names = destinations.map(&:name)
        duplicate = names.find { names.count(it) > 1 }
        raise ConfigurationError, "two destinations are named #{duplicate}; each keeps its own place by name" if duplicate
      end
  end
end
