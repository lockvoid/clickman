ClickMan.configure do |config|
  config.write_keys = { ios: 'dummy-ios-key' }
  config.base_controller_class = 'AdminController'
  config.publish_on_boot = false
end
