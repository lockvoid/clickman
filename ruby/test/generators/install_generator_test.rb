require 'test_helper'
require 'rails/generators/test_case'
require 'generators/clickman/install/install_generator'

module ClickMan
  class InstallGeneratorTest < Rails::Generators::TestCase
    tests Generators::InstallGenerator
    destination File.expand_path('../../tmp/generator', __dir__)
    setup :prepare_destination

    test 'install writes the initializer and the funnels folder and leaves the migrations to the engine' do
      output = run_generator

      assert_file 'config/initializers/clickman.rb' do |initializer|
        assert_match 'ClickMan.configure', initializer
        assert_no_match 'config.database', initializer
      end
      assert_file 'config/clickman/funnels/.keep'
      assert_no_directory 'db/migrate'
      assert_match 'bin/rails click_man:install:migrations && bin/rails db:migrate', output
    end

    test 'a separate database goes into the initializer and the migration command' do
      output = run_generator %w[--database analytics]

      assert_file 'config/initializers/clickman.rb', /config\.database = :analytics/
      assert_match 'bin/rails click_man:install:migrations DATABASE=analytics', output
    end
  end
end
