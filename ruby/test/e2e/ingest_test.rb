require 'test_helper'
require 'net/http'
require 'open3'
require 'socket'

module ClickMan
  class IngestTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    KEY = 'e2e-write-key'.freeze
    ANDROID_KEY = 'e2e-android-key'.freeze
    ROOT = File.expand_path('../../..', __dir__)
    TABLES = %w[
      clickman_events
      clickman_event_names
      clickman_keys
      clickman_actors
      clickman_chunks
      clickman_daily_counts
      clickman_actor_days
      clickman_reports
      clickman_settings
      clickman_cursors
    ].freeze

    setup do
      truncate
      @port = free_port
      ClickMan.configure do |config|
        config.write_keys = { ios: KEY }
        config.filter_fragments += %w[price]
        config.ingest_url = "http://127.0.0.1:#{@port}"
      end
      ClickMan.publish_settings!
    end

    teardown do
      @supervisor&.stop
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
        InlineSupervisor.new(launcher: RecordingLauncher.new, environment: -> { environment }).start
        sleep
      end
      eventually('the server') { healthy? }

      Process.kill('KILL', supervisor)
      Process.wait(supervisor)

      eventually('the port to be freed', seconds: 20) { !healthy? }
      assert_raises(Errno::ECONNREFUSED) { TCPSocket.new('127.0.0.1', @port) }
    end

    test 'the swift and kotlin clients reach the reports through the ingest server' do
      ClickMan.configure { it.write_keys = { ios: KEY, android: ANDROID_KEY } }
      ClickMan.publish_settings!
      start_ingest

      Dir.mktmpdir do |directory|
        client!('swift', 'run', '--package-path', ROOT, 'clickman-e2e-client', endpoint, KEY, File.join(directory, 'swift.sqlite'))
        client!(
          File.join(ROOT, 'kotlin/gradlew'), '--quiet', '-p', File.join(ROOT, 'kotlin'), ':clickman:e2eClient',
          "-Pendpoint=#{endpoint}", "-PwriteKey=#{ANDROID_KEY}", "-Pqueue=#{File.join(directory, 'kotlin.sqlite')}"
        )
      end

      exports = Event.where(event: 'export_completed').index_by(&:external_id)
      assert_equal %w[e2e-kotlin e2e-swift], exports.keys.sort
      exports.each_value do |export|
        assert_equal({ 'format' => 'mp4', 'contact.email' => '[FILTERED]' }, export.properties)
        assert_equal 'pro', export.context['traits.plan']
      end
      assert_equal %w[clickman-kotlin clickman-swift], exports.values.map { it.context['library.name'] }.sort
      assert_equal({ 'app_installed' => 2, 'app_opened' => 2 }, Event.where(external_id: ANONYMOUS).group(:event).count)

      assert_equal 6, ClickMan.rotate!(now: Time.current + 5.minutes)
      ClickMan.refresh_reports!(now: Time.current)
      totals = Report.find('events').result['events'].to_h { [it['event'], it['actors']] }
      assert_equal 2, totals['export_completed']
    end

    private

      def truncate
        TABLES.each { Record.lease_connection.execute("DELETE FROM #{it}") }
      end

      def environment
        InlineEnvironment.new.to_h.merge('CLICKMAN_INGEST_SETTINGS_REFRESH' => '1')
      end

      def start_ingest
        @supervisor = InlineSupervisor.new(launcher: RecordingLauncher.new, environment: -> { environment })
        @supervisor.start
        eventually('the server') { healthy? }
      end

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

      def endpoint
        "http://127.0.0.1:#{@port}"
      end

      def client!(*command)
        output, status = Open3.capture2e(*command)
        assert status.success?, "#{command.first(2).join(' ')} failed:\n#{output.last(3_000)}"
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

      def healthy?
        Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/health")).code == '200'
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError
        false
      end

      def free_port
        server = TCPServer.new('127.0.0.1', 0)
        server.addr[1].tap { server.close }
      end

      def eventually(what, seconds: 30)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
        until yield
          flunk "timed out waiting for #{what}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          sleep 0.1
        end
      end
  end
end
