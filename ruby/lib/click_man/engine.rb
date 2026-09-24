require 'rails/engine'

module ClickMan
  class Engine < ::Rails::Engine
    isolate_namespace ClickMan
    engine_name 'click_man'

    initializer 'click_man.funnels_path' do |app|
      ClickMan.configuration.funnels_path ||= app.root.join('config/clickman/funnels')
    end

    config.after_initialize do
      ClickMan.configuration.validate!
      ClickMan::Settings.publish_on_boot if ClickMan.configuration.publish_on_boot
    end

    rake_tasks do
      load File.expand_path('../tasks/clickman.rake', __dir__)
    end
  end
end
