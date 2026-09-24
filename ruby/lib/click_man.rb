require 'securerandom'
require 'zeitwerk'

module ClickMan
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class DeliveryError < Error; end

  ANONYMOUS = '*'.freeze

  LOADER = Zeitwerk::Loader.new.tap do |loader|
    loader.tag = 'clickman'
    loader.inflector.inflect('version' => 'VERSION', 'sqlite' => 'SQLite')
    loader.push_dir(__dir__)
    loader.ignore("#{__dir__}/clickman.rb")
    loader.ignore("#{__dir__}/puma")
    loader.ignore("#{__dir__}/generators")
    loader.ignore("#{__dir__}/tasks")
    loader.ignore("#{__dir__}/click_man/engine.rb")
    loader.setup
  end

  class << self
    def table_name_prefix
      'clickman_'
    end

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration
      configuration.validate!
    end

    def reset_configuration!
      @configuration = Configuration.new
    end

    def track(event, external_id:, properties: {}, context: {}, at: Time.current)
      sanitizer = configuration.sanitizer
      store.insert(
        [
          {
            message_id: SecureRandom.uuid_v7,
            occurred_at: at,
            received_at: Time.current,
            external_id: external_id.to_s,
            event: event.to_s,
            properties: sanitizer.call(Flatten.call(properties)),
            context: sanitizer.call(Flatten.call(context))
          }
        ]
      )
      true
    rescue StandardError => error
      Rails.error.report(error, handled: true, source: 'clickman')
      false
    end

    def store
      Stores.for(Record.connection_db_config.adapter)
    end

    def rotate!(now: Time.current)
      store.rotate!(now: now, lag: configuration.rotation_lag)
    end

    def prune!(now: Time.current)
      store.prune!(
        now: now,
        dedup_window: configuration.dedup_window,
        retention: configuration.retention,
        holds: configuration.destinations.map { Delivery.cursor_for(it) }
      )
    end

    def refresh_reports!(now: Time.current)
      Reports.new(store: store, funnels: Funnel.load(configuration.funnels_path)).refresh!(now: now)
    end

    def deliver!(now: Time.current)
      Delivery.new(store: store, destinations: configuration.destinations, lag: configuration.rotation_lag).deliver!(now: now)
    end

    def erase!(external_id, now: Time.current)
      store.erase!(external_id.to_s, now: now)
    end

    def publish_settings!
      Settings.publish!
    end
  end
end

require 'click_man/engine' if defined?(Rails::Engine)
