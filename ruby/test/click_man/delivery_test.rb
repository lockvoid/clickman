require 'test_helper'

module ClickMan
  class DeliveryTest < ActiveSupport::TestCase
    NOW = Time.iso8601('2026-09-23T12:00:00Z')

    test 'a destination receives every event once, in order, page by page' do
      destination = RecordingDestination.new(batch_size: 2)
      ClickMan.configure { it.destinations = [destination] }
      %w[a b c].each_with_index do |name, index|
        raw(name, external_id: 'user_1', at: NOW - 10.minutes + index.seconds, properties: { n: index })
      end

      assert_equal 3, ClickMan.deliver!(now: NOW)
      assert_equal 0, ClickMan.deliver!(now: NOW)

      assert_equal [%w[a b], %w[c]], destination.deliveries.map { |page| page.map { it[:event] } }
      first = destination.deliveries.first.first
      assert_equal 'user_1', first[:external_id]
      assert_equal({ 'n' => 0 }, first[:properties])
      assert first[:message_id].present?
    end

    test 'events younger than the rotation lag wait for the next delivery' do
      destination = RecordingDestination.new
      ClickMan.configure { it.destinations = [destination] }
      raw('fresh', external_id: 'user_1', at: NOW - 30.seconds)

      assert_equal 0, ClickMan.deliver!(now: NOW)
      assert_equal 1, ClickMan.deliver!(now: NOW + 5.minutes)
    end

    test 'a failing destination keeps its place and the others go on' do
      failing = RecordingDestination.new(fail_with: IOError.new('mixpanel is down'))
      working = RecordingDestination.new
      def working.name
        'working'
      end
      ClickMan.configure { it.destinations = [failing, working] }
      raw('a', external_id: 'user_1', at: NOW - 10.minutes)

      error = assert_raises(ClickMan::DeliveryError) { ClickMan.deliver!(now: NOW) }

      assert_match 'recording', error.message
      assert_equal 1, working.deliveries.flatten.size
      assert_nil ClickMan::Cursor.find_by(name: 'destination:recording')
    end

    test 'mixpanel receives its import format' do
      sent = []
      mixpanel = ClickMan::Destinations::Mixpanel.new(
        project_id: '123',
        username: 'service-account',
        secret: 'service-secret',
        transport: ->(request) { sent << request and [200, '{"code":200,"num_records_imported":1,"status":"OK"}'] }
      )
      event = {
        message_id: '01926a2e-7b1c-7c3d-9f2e-5b1a2c3d4e5f',
        event: 'export_completed',
        external_id: 'user_1',
        occurred_at: Time.iso8601('2026-09-23T10:00:00.123Z'),
        properties: { 'format' => 'mp4' },
        context: { 'os.name' => 'iOS' }
      }

      mixpanel.deliver([event])

      request = sent.sole
      assert_equal 'https://api.mixpanel.com/import?strict=1&project_id=123', request[:url]
      assert_equal "Basic #{Base64.strict_encode64('service-account:service-secret')}", request[:headers]['Authorization']
      assert_equal(
        [
          {
            'event' => 'export_completed',
            'properties' => {
              'time' => 1_790_157_600_123,
              'distinct_id' => 'user_1',
              '$insert_id' => '01926a2e-7b1c-7c3d-9f2e-5b1a2c3d4e5f',
              'format' => 'mp4',
              'context.os.name' => 'iOS'
            }
          }
        ],
        JSON.parse(ActiveSupport::Gzip.decompress(request[:body]))
      )
    end

    test 'anonymous events reach mixpanel without a user and the region picks the host' do
      sent = []
      mixpanel = ClickMan::Destinations::Mixpanel.new(
        project_id: '123', username: 'u', secret: 's', region: :eu,
        transport: ->(request) { sent << request and [200, '{}'] }
      )

      mixpanel.deliver([mixpanel_event(external_id: ClickMan::ANONYMOUS)])

      assert_equal 'https://api-eu.mixpanel.com/import?strict=1&project_id=123', sent.sole[:url]
      assert_equal '', JSON.parse(ActiveSupport::Gzip.decompress(sent.sole[:body])).sole['properties']['distinct_id']
    end

    test 'events mixpanel refuses are reported, since sending them again cannot help' do
      mixpanel = mixpanel_answering(400, '{"code":400,"error":"some data points in the request failed validation"}')

      assert_error_reported(ClickMan::DeliveryError) { mixpanel.deliver([mixpanel_event]) }
    end

    test 'mixpanel being unavailable is an error the delivery retries' do
      mixpanel = mixpanel_answering(503, 'upstream unavailable')

      error = assert_raises(ClickMan::DeliveryError) { mixpanel.deliver([mixpanel_event]) }
      assert_match '503', error.message
    end

    test 'a batch over ten megabytes goes to mixpanel in several requests' do
      sent = []
      mixpanel = ClickMan::Destinations::Mixpanel.new(
        project_id: '123', username: 'u', secret: 's',
        transport: ->(request) { sent << request and [200, '{}'] }
      )
      wide = (1..6).to_h { ["text_#{it}", 'x' * 1_024] }

      mixpanel.deliver(Array.new(2_000) { mixpanel_event(properties: wide) })

      bodies = sent.map { ActiveSupport::Gzip.decompress(it[:body]) }
      assert_equal 2, bodies.size
      assert_equal 2_000, bodies.sum { JSON.parse(it).size }
      assert(bodies.all? { it.bytesize <= ClickMan::Destinations::Mixpanel::MAX_BODY_BYTES })
    end

    def mixpanel_answering(status, body)
      ClickMan::Destinations::Mixpanel.new(project_id: '123', username: 'u', secret: 's', transport: ->(_request) { [status, body] })
    end

    def mixpanel_event(external_id: 'user_1', properties: {})
      {
        message_id: SecureRandom.uuid_v7,
        event: 'export_completed',
        external_id: external_id,
        occurred_at: NOW,
        properties: properties,
        context: {}
      }
    end
  end
end
