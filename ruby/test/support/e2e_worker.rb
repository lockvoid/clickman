require 'json'
require 'open3'
require 'timeout'

class E2EWorker
  ROOT = File.expand_path('../../..', __dir__)
  BINARIES = {
    'swift' => File.join(ROOT, '.build/debug/ClickManE2EWorker'),
    'kotlin' => File.join(ROOT, 'kotlin/e2e-worker/build/install/e2e-worker/bin/e2e-worker'),
    'rust' => File.join(ROOT, 'rust/target/debug/clickman-e2e-worker')
  }.freeze
  ANSWER_TIMEOUT = 60

  attr_reader :language

  def initialize(language, endpoint:, write_key:, store:)
    @language = language
    binary = BINARIES.fetch(language)
    raise "#{binary} is missing; bundle exec rake e2e:build" unless File.executable?(binary)

    @stdin, @stdout, @stderr, @process = Open3.popen3(binary, endpoint, write_key, store)
    @log = Thread.new { @stderr.read }
    ready = answer
    raise "#{language} worker started as #{ready}" unless ready == { 'ready' => true, 'language' => language }
  end

  def call(command, **arguments)
    @stdin.puts(JSON.generate({ command: command, **arguments }))
    @stdin.flush
    reply = answer
    raise "#{language} #{command}: #{reply['error']}" unless reply['ok']

    reply
  end

  def stop
    @stdin.close
    status = @process.value
    raise "#{language} worker exited with #{status}:\n#{@log.value}" unless status.success?
  end

  def kill
    Process.kill('KILL', @process.pid)
    @process.value
  end

  private

    def answer
      line = Timeout.timeout(ANSWER_TIMEOUT) { @stdout.gets }
      raise "#{language} worker closed its output:\n#{@log.value}" unless line

      JSON.parse(line)
    end
end
