module ClickMan
  class DeliveryJob < ActiveJob::Base
    def perform
      ClickMan.deliver!
    end
  end
end
