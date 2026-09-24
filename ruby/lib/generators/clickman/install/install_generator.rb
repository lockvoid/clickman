require 'rails/generators'
require 'rails/generators/active_record'

module ClickMan
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      SCHEMAS = File.expand_path('../../../../../sql', __dir__)

      namespace 'clickman:install'
      source_root File.expand_path('templates', __dir__)

      class_option :database, type: :string, desc: 'The database.yml name ClickMan keeps its tables in, e.g. analytics'

      def create_migration_file
        migration_template 'create_clickman_tables.rb.tt', File.join(db_migrate_path, 'create_clickman_tables.rb')
      end

      def create_initializer
        template 'clickman.rb.tt', 'config/initializers/clickman.rb'
      end

      def create_funnels_directory
        create_file 'config/clickman/funnels/.keep', ''
      end

      def show_next_steps
        say <<~TEXT

          ClickMan is installed. Next:
            1. bin/rails db:migrate
            2. Mount the dashboard, e.g. `mount ClickMan::Engine, at: '/analytics'`, and set
               config.base_controller_class to a controller that lets only your team in.
            3. Run ClickMan::RotationJob every hour, and ClickMan::DeliveryJob when events go to destinations.
            4. In development, `plugin :clickman` in config/puma.rb runs the ingest server beside Puma.
        TEXT
      end

      def self.schema_for(adapter)
        directory = adapter.to_s.include?('sqlite') ? 'sqlite' : 'postgres'
        File.read(File.join(SCHEMAS, directory, 'v1.sql'))
      end

      private

        def statements
          self.class.schema_for(database_config.adapter).split(/;\s*$/).map(&:strip).reject(&:empty?)
        end

        def database_config
          ActiveRecord::Base.configurations.configs_for(env_name: Rails.env, name: options[:database] || 'primary') ||
            ActiveRecord::Base.configurations.configs_for(env_name: Rails.env).first
        end
    end
  end
end
