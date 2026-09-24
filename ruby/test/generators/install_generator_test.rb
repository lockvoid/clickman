require 'test_helper'
require 'rails/generators/test_case'
require 'generators/clickman/install/install_generator'

module ClickMan
  class InstallGeneratorTest < Rails::Generators::TestCase
    tests Generators::InstallGenerator
    destination File.expand_path('../../tmp/generator', __dir__)
    setup :prepare_destination

    test 'install writes the schema migration, the initializer and the funnels folder' do
      run_generator

      assert_migration 'db/migrate/create_clickman_tables.rb' do |migration|
        statements = migration.scan(/execute <<~SQL\n(.*?)^    SQL$/m).flatten.map { it.gsub(/^ {6}/, '').strip }
        schema = Generators::InstallGenerator.schema_for(ClickManTestDatabase.adapter)
        assert_equal schema.split(/;\s*$/).map(&:strip).reject(&:empty?), statements
      end
      assert_file 'config/initializers/clickman.rb' do |initializer|
        assert_match 'ClickMan.configure', initializer
        assert_no_match 'config.database', initializer
      end
      assert_file 'config/clickman/funnels/.keep'
    end

    test 'a separate database goes into the initializer' do
      run_generator %w[--database analytics]

      assert_file 'config/initializers/clickman.rb', /config\.database = :analytics/
    end

    test 'the migration it writes takes the schema down and builds it again' do
      run_generator
      load Dir[File.join(destination_root, 'db/migrate/*_create_clickman_tables.rb')].sole
      migration = CreateClickmanTables.new
      migration.verbose = false
      connection = ActiveRecord::Base.lease_connection

      migration.migrate(:down)
      assert_empty CreateClickmanTables::TABLES.select { connection.table_exists?(it) }

      migration.migrate(:up)
      assert_equal CreateClickmanTables::TABLES.sort, CreateClickmanTables::TABLES.select { connection.table_exists?(it) }.sort
    end
  end
end
