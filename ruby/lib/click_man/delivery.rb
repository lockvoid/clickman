module ClickMan
  class Delivery
    def self.cursor_for(destination)
      "destination:#{destination.name}"
    end

    def initialize(store:, destinations:, lag:)
      @store = store
      @destinations = destinations
      @lag = lag
    end

    def deliver!(now:)
      failures = []

      delivered = @destinations.sum do |destination|
        deliver_to(destination, before: now - @lag)
      rescue StandardError => error
        failures << [destination, error]
        0
      end

      if failures.any?
        message = failures.map { |destination, error| "#{destination.name}: #{error.class}: #{error.message}" }.join('; ')
        raise DeliveryError, message, cause: failures.first.last
      end

      delivered
    end

    private

      def deliver_to(destination, before:)
        cursor = self.class.cursor_for(destination)
        delivered = 0

        loop do
          events = @store.pending(cursor: cursor, before: before, limit: destination.batch_size)
          break if events.empty?

          destination.deliver(events)
          @store.advance!(cursor: cursor, to: events.last)
          delivered += events.size
          break if events.size < destination.batch_size
        end

        delivered
      end
  end
end
