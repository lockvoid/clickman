require 'msgpack'
require 'zstd-ruby'

module ClickMan
  module Columns
    VERSION = 1
    PACKABLE_INTEGERS = (-(2**63)..(2**64) - 1)

    class << self
      def encode(times:, actors:, columns:)
        deltas = times.each_with_index.map { |time, index| index.zero? ? time : time - times[index - 1] }
        packed = columns.map { |key_id, values| [key_id, values.map { packable(it) }] }
        Zstd.compress(MessagePack.pack({ 'v' => VERSION, 't' => deltas, 'a' => actors, 'c' => packed }))
      end

      def decode(payload)
        unpacked = MessagePack.unpack(Zstd.decompress(payload))
        verify_version!(unpacked['v'])

        total = 0
        times = unpacked['t'].map { total += it }

        { times: times, actors: unpacked['a'], columns: unpacked['c'].to_h }
      end

      def actors(payload)
        unpacker = MessagePack::Unpacker.new
        unpacker.feed(Zstd.decompress(payload))

        unpacker.read_map_header.times do
          case unpacker.read
          when 'v'
            verify_version!(unpacker.read)
          when 'a'
            return unpacker.read
          else
            unpacker.skip
          end
        end

        raise ArgumentError, 'chunk payload has no actors'
      end

      private

        def packable(value)
          value.is_a?(Integer) && !PACKABLE_INTEGERS.cover?(value) ? value.to_f : value
        end

        def verify_version!(version)
          raise ArgumentError, "unknown chunk payload version #{version}" unless version == VERSION
        end
    end
  end
end
