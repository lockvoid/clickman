require 'test_helper'

module ClickMan
  class InlineEnvironmentTest < ActiveSupport::TestCase
    def environment(database_config, ingest_url: 'http://127.0.0.1:4130')
      configuration = Configuration.new
      configuration.ingest_url = ingest_url
      InlineEnvironment.new(configuration: configuration, database_config: database_config).to_h
    end

    test 'the ingest server binds where the configuration says and reaches the ClickMan database' do
      config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
        'development', 'analytics',
        { adapter: 'postgresql', database: 'analytics', host: 'db.internal', port: 5433, username: 'clickman', password: 'secret', sslmode: 'require' }
      )

      assert_equal(
        {
          'CLICKMAN_INGEST_BIND' => '0.0.0.0:4200',
          'DATABASE_URL' => 'postgresql://',
          'PGDATABASE' => 'analytics',
          'PGHOST' => 'db.internal',
          'PGPORT' => '5433',
          'PGUSER' => 'clickman',
          'PGPASSWORD' => 'secret',
          'PGSSLMODE' => 'require'
        },
        environment(config, ingest_url: 'http://0.0.0.0:4200')
      )
    end

    test 'a database given by url reaches the ingest server in parts' do
      config = ActiveRecord::DatabaseConfigurations::UrlConfig.new(
        'development', 'analytics', 'postgres://clickman:s%40cret@db.internal:5433/analytics?sslmode=require', {}
      )

      variables = environment(config)

      assert_equal %w[analytics db.internal 5433 clickman s@cret require], variables.values_at('PGDATABASE', 'PGHOST', 'PGPORT', 'PGUSER', 'PGPASSWORD', 'PGSSLMODE')
      assert_equal 'postgresql://', variables['DATABASE_URL']
    end

    test 'a SQLite database reaches the ingest server as a sqlite url to the same file' do
      config = ActiveRecord::DatabaseConfigurations::HashConfig.new('development', 'analytics', { adapter: 'sqlite3', database: 'storage/analytics.sqlite3' })

      assert_equal(
        { 'CLICKMAN_INGEST_BIND' => '127.0.0.1:4130', 'DATABASE_URL' => "sqlite://#{Rails.root.join('storage/analytics.sqlite3')}" },
        environment(config)
      )
    end

    test 'the plugin refuses a ClickMan database the ingest server cannot write' do
      config = ActiveRecord::DatabaseConfigurations::HashConfig.new('development', 'analytics', { adapter: 'mysql2', database: 'analytics' })

      assert_raises(ConfigurationError) { environment(config) }
    end
  end
end
