require 'test_helper'

module ClickMan
  class ClientsTest < ActiveSupport::TestCase
    include IngestServer

    self.use_transactional_tests = false

    LANGUAGES = E2EWorker::BINARIES.keys.freeze

    setup do
      truncate
      serve(LANGUAGES.to_h { [it.to_sym, "e2e-#{it}-key"] })
      start_ingest
      @stores = Dir.mktmpdir('clickman-e2e')
    end

    teardown do
      stop_ingest
      truncate
      FileUtils.rm_rf(@stores)
    end

    LANGUAGES.each do |language|
      test "the #{language} client delivers what it tracked, sanitized, with its traits and its launch" do
        worker = start(language)
        worker.call('identify', externalId: "e2e-#{language}")
        worker.call('traits', traits: { plan: 'pro' })
        worker.call('track', event: 'export_completed', properties: { format: 'mp4', contact: { email: 'a@b.co' } })
        assert_equal 0, worker.call('flush')['pending']
        worker.stop

        export = Event.find_by!(event: 'export_completed')
        assert_equal "e2e-#{language}", export.external_id
        assert_equal({ 'format' => 'mp4', 'contact.email' => '[FILTERED]' }, export.properties)
        assert_equal 'pro', export.context['traits.plan']
        assert_equal "clickman-#{language}", export.context['library.name']
        assert_equal({ 'app_installed' => 1, 'app_opened' => 1 }, Event.where(external_id: ANONYMOUS).group(:event).count)
      end

      test "the #{language} client keeps what it tracked offline through a kill and sends it once afterwards" do
        offline = start(language, endpoint: "http://127.0.0.1:#{free_port}")
        3.times { offline.call('track', event: 'offline_edit', properties: { index: it }) }
        assert_equal 5, offline.call('flush')['pending']
        offline.kill

        online = start(language)
        assert_equal 0, online.call('flush')['pending']
        online.stop

        assert_equal [0, 1, 2], Event.where(event: 'offline_edit').map { it.properties['index'] }.sort
        assert_equal({ 'app_installed' => 1, 'app_opened' => 2, 'offline_edit' => 3 }, Event.group(:event).count)
      end
    end

    test 'the three clients reach the reports through the ingest server' do
      LANGUAGES.each do |language|
        worker = start(language)
        worker.call('identify', externalId: "e2e-#{language}")
        worker.call('track', event: 'export_completed', properties: { format: 'mp4' })
        assert_equal 0, worker.call('flush')['pending']
        worker.stop
      end

      assert_equal 9, ClickMan.rotate!(now: Time.current + 5.minutes)
      ClickMan.refresh_reports!(now: Time.current)
      totals = Report.find('events').result['events'].to_h { [it['event'], [it['events'], it['actors']]] }
      assert_equal [3, 3], totals['export_completed']
    end

    private

      def start(language, endpoint: self.endpoint)
        E2EWorker.new(language, endpoint: endpoint, write_key: "e2e-#{language}-key", store: File.join(@stores, "#{language}.sqlite"))
      end
  end
end
