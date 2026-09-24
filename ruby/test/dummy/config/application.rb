require 'rails'
require 'active_record/railtie'
require 'active_job/railtie'
require 'action_controller/railtie'
require 'action_view/railtie'
require 'clickman'

module Dummy
  class Application < Rails::Application
    config.root = File.expand_path('..', __dir__)
    config.load_defaults 8.0
    config.eager_load = true
    config.logger = Logger.new(File::NULL)
    config.active_job.queue_adapter = :test
    config.secret_key_base = 'clickman-dummy-secret-key-base'
    config.hosts.clear
    config.active_record.maintain_test_schema = false
    config.action_dispatch.show_exceptions = :rescuable
  end
end
