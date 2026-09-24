require 'test_helper'

module ClickMan
  class InlineSupervisorTest < ActiveSupport::TestCase
    SERVER = <<~RUBY.freeze
      File.open(File.join(ARGV[0], 'pids'), 'a') { it.puts(Process.pid) }
      File.write(File.join(ARGV[0], 'supervised'), ENV.fetch('CLICKMAN_INGEST_SUPERVISED'))
      $stdin.read
    RUBY

    CRASHING_TWICE = <<~RUBY.freeze
      path = File.join(ARGV[0], 'pids')
      File.open(path, 'a') { it.puts(Process.pid) }
      exit(1) if File.readlines(path).size < 3
      $stdin.read
    RUBY

    setup do
      @directory = Dir.mktmpdir
      @launcher = RecordingLauncher.new
    end

    teardown do
      @supervisor&.stop
      FileUtils.remove_entry(@directory)
    end

    def supervise(script)
      @supervisor = InlineSupervisor.new(
        launcher: @launcher,
        command: [Gem.ruby, '-e', script, @directory],
        environment: -> { { 'CLICKMAN_INGEST_BIND' => '127.0.0.1:4130' } }
      )
    end

    def pids
      path = File.join(@directory, 'pids')
      File.exist?(path) ? File.readlines(path).map(&:to_i) : []
    end

    def alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end

    def eventually(what)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      until yield
        flunk "timed out waiting for #{what}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.05
      end
    end

    test 'the ingest server runs supervised until Puma stops it' do
      supervise(SERVER).start
      eventually('the server') { pids.one? && File.exist?(File.join(@directory, 'supervised')) }

      assert alive?(pids.sole)
      assert_equal '1', File.read(File.join(@directory, 'supervised'))

      assert @supervisor.stop
      assert_not alive?(pids.sole)
    end

    test 'a crashed ingest server is respawned' do
      supervise(CRASHING_TWICE).start

      eventually('the third server') { pids.size == 3 }
      eventually('the third server to stay up') { @launcher.lines.count { it.include?('respawning') } == 2 }
      assert alive?(pids.last)
    end

    test 'a server that keeps crashing is given up without stopping Puma' do
      supervise('exit 1').start

      eventually('the supervisor to give up') { @launcher.lines.any? { it.include?('clients keep their events queued') } }
      assert_equal 3, @launcher.lines.count { it.include?('respawning') }
    end

    test 'the ingest server dies with a supervisor that dies without stopping it' do
      supervisor = fork do
        supervise(SERVER).start
        sleep
      end
      eventually('the server') { pids.one? }
      server = pids.sole

      Process.kill('KILL', supervisor)
      Process.wait(supervisor)

      eventually('the orphaned server to exit') { !alive?(server) }
    end
  end
end
