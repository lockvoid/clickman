require 'test_helper'

load File.join(ClickManTestDatabase::MIGRATIONS, '20260924053115_create_click_man_tables.rb')

module ClickMan
  class CreateClickManTablesTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    TABLES = %w[
      clickman_events
      clickman_event_names
      clickman_keys
      clickman_actors
      clickman_chunks
      clickman_daily_counts
      clickman_actor_days
      clickman_reports
      clickman_settings
      clickman_cursors
    ].freeze

    test 'the migration takes the schema down and builds it again' do
      migration = CreateClickManTables.new
      migration.verbose = false

      migration.migrate(:down)
      assert_empty TABLES.select { connection.table_exists?(it) }

      migration.migrate(:up)
      assert_equal TABLES.sort, TABLES.select { connection.table_exists?(it) }.sort
    end

    test 'the engine offers its migration to the host' do
      assert_equal [ClickManTestDatabase::MIGRATIONS], ClickMan::Engine.paths['db/migrate'].existent
    end

    private

      def connection
        ActiveRecord::Base.lease_connection
      end
  end
end
