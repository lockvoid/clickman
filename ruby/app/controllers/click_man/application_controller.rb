module ClickMan
  class ApplicationController < (ClickMan.configuration.base_controller_class || 'ActionController::Base').constantize
    layout 'click_man/application'
    helper ApplicationHelper

    before_action :require_base_controller

    private

      def require_base_controller
        return if ClickMan.configuration.base_controller_class

        raise ConfigurationError, 'set config.base_controller_class to a controller of yours that lets only your team in; ' \
                                  'the dashboard shows how people use your product'
      end
  end
end
