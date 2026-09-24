module ClickMan
  class Store
    CHUNK_EVENTS = 4_096
    RETURN_DAYS = [1, 7, 30].freeze
    ROTATION_CURSOR = 'rotation'.freeze

    Occurrence = Data.define(:at, :actor, :event, :fields)

    def insert(events)
      raise NotImplementedError, "#{self.class} must implement insert(events)"
    end

    def rotate!(now:, lag:)
      raise NotImplementedError, "#{self.class} must implement rotate!(now:, lag:)"
    end

    def prune!(now:, dedup_window:, retention:, holds:)
      raise NotImplementedError, "#{self.class} must implement prune!(now:, dedup_window:, retention:, holds:)"
    end

    def erase!(external_id, now:)
      raise NotImplementedError, "#{self.class} must implement erase!(external_id, now:)"
    end

    def pending(cursor:, before:, limit:)
      raise NotImplementedError, "#{self.class} must implement pending(cursor:, before:, limit:)"
    end

    def advance!(cursor:, to:)
      raise NotImplementedError, "#{self.class} must implement advance!(cursor:, to:)"
    end

    def actives(from:, to:)
      raise NotImplementedError, "#{self.class} must implement actives(from:, to:)"
    end

    def cohorts(from:, to:)
      raise NotImplementedError, "#{self.class} must implement cohorts(from:, to:)"
    end

    def event_totals(from:, to:)
      raise NotImplementedError, "#{self.class} must implement event_totals(from:, to:)"
    end

    def each_event(names:, from:, to:, keys:)
      raise NotImplementedError, "#{self.class} must implement each_event(names:, from:, to:, keys:)"
    end
  end
end
