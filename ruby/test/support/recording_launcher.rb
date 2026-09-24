class RecordingLauncher
  attr_reader :lines

  def initialize
    @lines = []
  end

  def log_writer
    self
  end

  def log(message)
    @lines << message
  end

  def error(message)
    @lines << message
  end
end
