require 'test_helper'

module ClickMan
  class JobsTest < ActiveSupport::TestCase
    test 'the rotation job rotates, prunes and refreshes the reports' do
      raw('app_opened', external_id: 'user_1', at: 10.minutes.ago)

      ClickMan::RotationJob.perform_now

      assert_equal 1, ClickMan::DailyCount.sole.events
      assert_equal %w[actives events retention], ClickMan::Report.order(:key).pluck(:key)
    end

    test 'the delivery job forwards new events to every destination' do
      destination = RecordingDestination.new
      ClickMan.configure { it.destinations = [destination] }
      raw('app_opened', external_id: 'user_1', at: 10.minutes.ago)

      ClickMan::DeliveryJob.perform_now

      assert_equal ['app_opened'], destination.deliveries.flatten.map { it[:event] }
    end
  end
end
