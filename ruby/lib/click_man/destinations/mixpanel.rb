require 'base64'
require 'json'

module ClickMan
  module Destinations
    class Mixpanel < Destination
      HOSTS = { us: 'api.mixpanel.com', eu: 'api-eu.mixpanel.com', in: 'api-in.mixpanel.com' }.freeze
      MAX_EVENTS = 2_000
      MAX_BODY_BYTES = 10 * 1024 * 1024

      def initialize(project_id:, username:, secret:, region: :us, transport: Transport.new)
        super()
        @url = "https://#{HOSTS.fetch(region)}/import?strict=1&project_id=#{project_id}"
        @headers = {
          'Authorization' => "Basic #{Base64.strict_encode64("#{username}:#{secret}")}",
          'Content-Type' => 'application/json',
          'Content-Encoding' => 'gzip',
          'Accept' => 'application/json'
        }
        @transport = transport
      end

      def name
        'mixpanel'
      end

      def batch_size
        MAX_EVENTS
      end

      def deliver(events)
        bodies(events.map { JSON.generate(record(it)) }).each { post(it) }
      end

      private

        def record(event)
          reserved = {
            'time' => (event[:occurred_at].to_r * 1000).floor,
            'distinct_id' => event[:external_id] == ANONYMOUS ? '' : event[:external_id],
            '$insert_id' => event[:message_id]
          }

          { 'event' => event[:event], 'properties' => event[:properties].merge(event[:context].transform_keys { "context.#{it}" }, reserved) }
        end

        def bodies(records)
          groups = [[]]
          bytes = 2

          records.each do |record|
            if groups.last.any? && bytes + record.bytesize + 1 > MAX_BODY_BYTES
              groups << []
              bytes = 2
            end
            groups.last << record
            bytes += record.bytesize + 1
          end

          groups.map { "[#{it.join(',')}]" }
        end

        # strict=1 imports the valid events of a 400 and lists the rest; sending
        # the batch again cannot fix them, so the refusal is reported, not retried.
        def post(body)
          status, response = @transport.call({ url: @url, headers: @headers, body: ActiveSupport::Gzip.compress(body) })
          return if status == 200

          error = DeliveryError.new("Mixpanel answered #{status}: #{response}")
          raise error unless status == 400

          Rails.error.report(error, handled: true, source: 'clickman')
        end
    end
  end
end
