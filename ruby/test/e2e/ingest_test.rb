require 'test_helper'

module ClickMan
  class IngestTest < ActiveSupport::TestCase
    include IngestServer

    self.use_transactional_tests = false

    KEY = 'e2e-write-key'.freeze

    setup do
      truncate
      serve(ios: KEY)
    end

    teardown do
      stop_ingest
      truncate
    end

    test 'events a client posts are deduplicated, clock-corrected, sanitized and rotated into the reports' do
      start_ingest
      skew = 1.hour
      sent_at = Time.current - skew
      batch = {
        sentAt: sent_at.iso8601(3),
        batch: [
          track('app_opened', '42', at: sent_at - 10.seconds, properties: { source: 'push', contact: { email: 'a@b.co' } }, context: { os: { name: 'iOS' } }),
          track('export_completed', '42', at: sent_at - 5.seconds, properties: { format: 'mp4', price: 9.99 }),
          track('app_opened', ANONYMOUS, at: sent_at - 1.second)
        ]
      }

      assert_equal [202, { 'accepted' => 3, 'duplicates' => 0, 'rejected' => [] }], post(batch)
      assert_equal [202, { 'accepted' => 0, 'duplicates' => 3, 'rejected' => [] }], post(batch)
      assert_equal 401, post(batch, key: 'not-the-key').first

      opened = Event.find(batch[:batch].first[:messageId])
      assert_equal({ 'source' => 'push', 'contact.email' => '[FILTERED]' }, opened.properties)
      assert_equal({ 'os.name' => 'iOS' }, opened.context)
      assert_in_delta (Time.current - 10.seconds).to_f, opened.occurred_at.to_f, 5
      assert_equal '[FILTERED]', Event.find(batch[:batch].second[:messageId]).properties['price']

      assert_equal 3, ClickMan.rotate!(now: Time.current + 5.minutes)
      ClickMan.refresh_reports!(now: opened.occurred_at)

      assert_equal 1, Report.find('actives').result['days'].last['dau']
      totals = Report.find('events').result['events'].to_h { [it['event'], [it['events'], it['actors']]] }
      assert_equal({ 'app_opened' => [2, 1], 'export_completed' => [1, 1] }, totals)
    end

    test 'a write key published while the server runs is accepted after the next settings refresh' do
      start_ingest
      batch = { sentAt: Time.current.iso8601(3), batch: [track('app_opened', '7', at: Time.current)] }
      assert_equal 401, post(batch, key: 'android-key').first

      ClickMan.configure { it.write_keys = { ios: KEY, android: 'android-key' } }
      ClickMan.publish_settings!

      eventually('the new key') { post(batch, key: 'android-key').first == 202 }
    end

    test 'the ingest server frees its port when its supervisor dies without stopping it' do
      supervisor = fork do
        InlineSupervisor.new(launcher: RecordingLauncher.new, environment: -> { ingest_environment }).start
        sleep
      end
      eventually('the server') { healthy? }

      Process.kill('KILL', supervisor)
      Process.wait(supervisor)

      eventually('the port to be freed', seconds: 20) { !healthy? }
      assert_raises(Errno::ECONNREFUSED) { TCPSocket.new('127.0.0.1', @port) }
    end

    private

      def track(event, external_id, at:, properties: {}, context: {})
        {
          type: 'track',
          messageId: SecureRandom.uuid_v7,
          event: event,
          externalId: external_id,
          timestamp: at.iso8601(3),
          properties: properties,
          context: context
        }
      end

      def post(batch, key: KEY)
        response = Net::HTTP.post(
          URI("#{endpoint}/v1/batch"),
          ActiveSupport::Gzip.compress(JSON.generate(batch)),
          'Authorization' => "Bearer #{key}",
          'Content-Type' => 'application/json',
          'Content-Encoding' => 'gzip'
        )
        [response.code.to_i, response.body.present? ? JSON.parse(response.body) : nil]
      end
  end
end
