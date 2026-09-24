require 'test_helper'
require 'msgpack'
require 'zstd-ruby'

module ClickMan
  class ColumnsTest < ActiveSupport::TestCase
    test 'a chunk payload round-trips its columns' do
      payload = ClickMan::Columns.encode(
        times: [1_000, 1_000, 86_399_999],
        actors: [7, 8, 7],
        columns: { 3 => ['mp4', nil, 'mov'], 5 => [nil, 2.5, true] }
      )

      decoded = ClickMan::Columns.decode(payload)

      assert_equal [1_000, 1_000, 86_399_999], decoded[:times]
      assert_equal [7, 8, 7], decoded[:actors]
      assert_equal({ 3 => ['mp4', nil, 'mov'], 5 => [nil, 2.5, true] }, decoded[:columns])
    end

    test 'repeated values compress to a fraction of their raw size' do
      events = 4_096
      raw_bytes = events * '{"format":"mp4","context.os.name":"iOS","context.app.version":"1.40"}'.bytesize

      payload = ClickMan::Columns.encode(
        times: (0...events).map { it * 1_000 },
        actors: (0...events).map { it % 300 },
        columns: { 1 => ['mp4'] * events, 2 => ['iOS'] * events, 3 => ['1.40'] * events }
      )

      assert_operator payload.bytesize, :<, raw_bytes / 20
    end

    test 'a payload of an unknown version is refused' do
      payload = Zstd.compress(MessagePack.pack({ 'v' => 99, 't' => [], 'a' => [], 'c' => [] }))

      assert_raises(ArgumentError) { ClickMan::Columns.decode(payload) }
    end
  end
end
