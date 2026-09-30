require 'rails/generators'

module ClickMan
  module Generators
    class InstallGenerator < Rails::Generators::Base
      namespace 'clickman:install'
      source_root File.expand_path('templates', __dir__)

      class_option :database, type: :string, desc: 'The database.yml name ClickMan keeps its tables in, e.g. analytics'

      def create_initializer
        template 'clickman.rb.tt', 'config/initializers/clickman.rb'
      end

      def create_funnels_directory
        create_file 'config/clickman/funnels/.keep', ''
      end

      def show_next_steps
        say <<~TEXT

          ClickMan is installed. Next:
            1. bin/rails click_man:install:migrations#{" DATABASE=#{options[:database]}" if options[:database]} && bin/rails db:migrate
            2. Mount the dashboard, e.g. `mount ClickMan::Engine, at: '/analytics'`, and set
               config.base_controller_class to a controller that lets only your team in.
            3. Run ClickMan::RotationJob every hour, and ClickMan::DeliveryJob when events go to destinations.
            4. In development, `plugin :clickman` in config/puma.rb runs the ingest server beside Puma.
        TEXT
      end
    end
  end
end
