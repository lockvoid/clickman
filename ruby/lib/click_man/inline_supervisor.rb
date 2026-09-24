module ClickMan
  # stdin is a lifeline (close_others, or EOF never comes); signal the process GROUP,
  # since `cargo run` outlives a TERM aimed at its leader.
  class InlineSupervisor
    SHUTDOWN_TIMEOUT = 5
    RESPAWN_LIMIT = 3
    RESPAWN_RESET_AFTER = 30
    EXECUTABLE = File.expand_path('../../bin/clickman-ingest', __dir__)

    def initialize(launcher:, command: [Gem.ruby, EXECUTABLE], environment: -> { InlineEnvironment.new.to_h })
      @log_writer = launcher.log_writer
      @command = command
      @environment = environment
      @mutex = Mutex.new
      @started = false
      @stopping = false
      @respawn_attempts = 0
    end

    def start
      @mutex.synchronize do
        return false if @started

        @stopping = false
        @respawn_attempts = 0
        @child_environment = @environment.call.merge('CLICKMAN_INGEST_SUPERVISED' => '1')
        spawn_locked
        @started = true
      end
      log("ingest server started (pid #{@pid}) on #{@child_environment['CLICKMAN_INGEST_BIND']}")
      true
    rescue StandardError
      stop
      raise
    end

    def stop
      pid, thread = @mutex.synchronize do
        return false if @stopping
        return false unless @started || @pid

        @stopping = true
        [@pid, @thread]
      end

      begin
        stop_child(pid, thread)
      ensure
        @mutex.synchronize do
          @pid = @thread = nil
          @lifeline&.close
          @lifeline = nil
          @started = false
        end
      end
      log('ingest server stopped')
      true
    end

    private

      def spawn_locked
        @lifeline&.close
        reader, @lifeline = IO.pipe
        @pid = Process.spawn(@child_environment, *@command, pgroup: true, close_others: true, in: reader)
        reader.close
        @spawned_at = monotonic
        pid = @pid
        @thread = Thread.new do
          Thread.current.name = 'clickman-ingest'
          monitor(pid)
        end
      end

      def monitor(pid)
        _pid, status = Process.wait2(pid)
        return if stopping? || respawn(status)

        log("ingest server exited with #{describe(status)}; clients keep their events queued until Puma restarts", error: true)
      rescue Errno::ECHILD => error
        log("ingest server could not be monitored: #{error.message}", error: true)
      end

      def respawn(status)
        @mutex.synchronize do
          return false if @stopping

          @respawn_attempts = 0 if monotonic - @spawned_at >= RESPAWN_RESET_AFTER
          return false if @respawn_attempts >= RESPAWN_LIMIT

          @respawn_attempts += 1
          log("ingest server exited with #{describe(status)}; respawning (attempt #{@respawn_attempts}/#{RESPAWN_LIMIT})", error: true)
          spawn_locked
          true
        end
      rescue StandardError => error
        log("ingest server respawn failed: #{error.message}", error: true)
        false
      end

      def stop_child(pid, thread)
        return unless pid

        signal('TERM', pid)
        return if settled?(pid, thread)

        log('ingest server process group did not stop in time; killing it', error: true)
        signal('KILL', pid)
        return if settled?(pid, thread)

        log('ingest server process group did not terminate', error: true)
      end

      def settled?(pid, thread)
        deadline = monotonic + SHUTDOWN_TIMEOUT

        loop do
          return true if !thread.alive? && !group_alive?(pid)

          remaining = deadline - monotonic
          return false unless remaining.positive?

          thread.join([remaining, 0.05].min)
        end
      end

      def signal(name, pid)
        Process.kill(name, -pid)
      rescue Errno::ESRCH
        nil
      end

      def group_alive?(pid)
        Process.kill(0, -pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def stopping?
        @mutex.synchronize { @stopping }
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def describe(status)
        return "exit status #{status.exitstatus}" if status.exited?
        return "signal #{status.termsig}" if status.signaled?

        status.to_s
      end

      def log(message, error: false)
        @log_writer.public_send(error ? :error : :log, "[clickman] #{message}")
      end
  end
end
