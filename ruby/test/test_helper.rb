ENV['RAILS_ENV'] = 'test'

require_relative 'dummy/config/environment'

module ClickManTestDatabase
  ROOT = File.expand_path('../..', __dir__)

  def self.adapter
    ActiveRecord::Base.connection_db_config.adapter
  end

  def self.postgres?
    adapter.include?('postg')
  end

  def self.prepare!
    postgres? ? prepare_postgres! : prepare_sqlite!
    ActiveRecord::Base.connection.schema_cache.clear!
    ActiveRecord::Base.descendants.each(&:reset_column_information)
  end

  def self.prepare_postgres!
    begin
      ActiveRecord::Base.connection.verify!
    rescue ActiveRecord::NoDatabaseError
      ActiveRecord::Tasks::DatabaseTasks.create(ActiveRecord::Base.connection_db_config)
    end

    connection = ActiveRecord::Base.connection
    connection.execute('DROP SCHEMA public CASCADE')
    connection.execute('CREATE SCHEMA public')
    connection.execute(File.read(File.join(ROOT, 'sql/postgres/v1.sql')))
  end

  def self.prepare_sqlite!
    database = ActiveRecord::Base.connection_db_config.database
    ActiveRecord::Base.connection_handler.clear_all_connections!
    FileUtils.mkdir_p(File.dirname(database))
    FileUtils.rm_f(Dir["#{database}*"])

    File.read(File.join(ROOT, 'sql/sqlite/v1.sql')).split(/;\s*$/).map(&:strip).reject(&:empty?).each do |statement|
      ActiveRecord::Base.connection.execute(statement)
    end
  end
end

ClickManTestDatabase.prepare!

require 'rails/test_help'

Dir[File.join(__dir__, 'support/**/*.rb')].each { require it }

class ActiveSupport::TestCase
  FIXTURES = File.expand_path('../../fixtures', __dir__)

  setup do
    ClickMan.reset_configuration!
    ClickMan.configure do |config|
      config.write_keys = { ios: 'dummy-ios-key' }
      config.base_controller_class = 'AdminController'
      config.publish_on_boot = false
    end
  end

  def fixture(name)
    JSON.parse(File.read(File.join(FIXTURES, name)))
  end

  def raw(event, external_id:, at:, properties: {}, context: {}, received_at: at)
    ClickMan.store.insert(
      [
        {
          message_id: SecureRandom.uuid_v7,
          occurred_at: at,
          received_at: received_at,
          external_id: external_id,
          event: event,
          properties: ClickMan::Flatten.call(properties),
          context: ClickMan::Flatten.call(context)
        }
      ]
    )
  end

  def day(text)
    Date.iso8601(text)
  end

  def utc(text)
    Time.iso8601(text)
  end
end
