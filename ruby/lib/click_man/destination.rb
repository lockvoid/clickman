module ClickMan
  class Destination
    def name
      self.class.name.demodulize.underscore
    end

    def batch_size
      1_000
    end

    def deliver(events)
      raise NotImplementedError, "#{self.class} must implement deliver(events)"
    end
  end
end
