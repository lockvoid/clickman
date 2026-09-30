require 'net/http'
require 'socket'

module IngestServer
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

  def truncate
    TABLES.each { ClickMan::Record.lease_connection.execute("DELETE FROM #{it}") }
  end

  def serve(write_keys)
    @port = free_port
    ClickMan.configure do |config|
      config.write_keys = write_keys
      config.filter_fragments += %w[price]
      config.ingest_url = endpoint
    end
    ClickMan.publish_settings!
  end

  def start_ingest
    @supervisor = ClickMan::InlineSupervisor.new(launcher: RecordingLauncher.new, environment: -> { ingest_environment })
    @supervisor.start
    eventually('the server') { healthy? }
  end

  def stop_ingest
    @supervisor&.stop
  end

  def ingest_environment
    ClickMan::InlineEnvironment.new.to_h.merge('CLICKMAN_INGEST_SETTINGS_REFRESH' => '1')
  end

  def endpoint
    "http://127.0.0.1:#{@port}"
  end

  def healthy?
    Net::HTTP.get_response(URI("#{endpoint}/health")).code == '200'
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
