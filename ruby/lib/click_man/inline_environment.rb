require 'uri'

module ClickMan
  class InlineEnvironment
    POSTGRES_VARIABLES = {
      database: 'PGDATABASE',
      host: 'PGHOST',
      port: 'PGPORT',
      username: 'PGUSER',
      password: 'PGPASSWORD',
      sslmode: 'PGSSLMODE',
      sslrootcert: 'PGSSLROOTCERT',
      sslcert: 'PGSSLCERT',
      sslkey: 'PGSSLKEY'
    }.freeze

    def initialize(configuration: ClickMan.configuration, database_config: Record.connection_db_config)
      @configuration = configuration
      @database_config = database_config
    end

    def to_h
      options = @database_config.configuration_hash

      case options[:adapter].to_s
      when /postg/
        variables = POSTGRES_VARIABLES.filter_map { |option, variable| [variable, options[option].to_s] if options[option].present? }
        { 'CLICKMAN_INGEST_BIND' => bind, 'DATABASE_URL' => 'postgresql://' }.merge(variables.to_h)
      when /sqlite/
        { 'CLICKMAN_INGEST_BIND' => bind, 'DATABASE_URL' => "sqlite://#{Rails.root.join(options[:database])}" }
      else
        raise ConfigurationError, "the ingest server writes to PostgreSQL or SQLite, not #{options[:adapter]}"
      end
    end

    private

      def bind
        uri = URI(@configuration.ingest_url)
        "#{uri.host}:#{uri.port}"
      end
  end
end
