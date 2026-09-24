class RecordingDestination < ClickMan::Destination
  attr_reader :deliveries

  def initialize(fail_with: nil, batch_size: 1_000)
    super()
    @fail_with = fail_with
    @batch_size = batch_size
    @deliveries = []
  end

  def name
    'recording'
  end

  def batch_size
    @batch_size
  end

  def deliver(events)
    raise @fail_with if @fail_with

    @deliveries << events
  end
end
