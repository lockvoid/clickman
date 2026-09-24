require 'test_helper'

module ClickMan
  class RotationTest < ActiveSupport::TestCase
    NOW = Time.iso8601('2026-09-23T12:00:00Z')

    def chunk_events(name)
      name_id = ClickMan::EventName.find_by!(name: name).id
      keys = ClickMan::Key.pluck(:id, :key).to_h
      actors = ClickMan::Actor.pluck(:id, :external_id).to_h

      ClickMan::Chunk.where(event_name_id: name_id).order(:day, :seq).flat_map do |chunk|
        decoded = ClickMan::Columns.decode(chunk.payload)
        decoded[:times].each_with_index.map do |ms, index|
          fields = decoded[:columns].filter_map { |key_id, values| [keys[key_id], values[index]] unless values[index].nil? }.to_h
          { at: chunk.day.to_time(:utc) + Rational(ms, 1000), actor: actors[decoded[:actors][index]], fields: fields }
        end
      end
    end

    def ticks(count, received_at:)
      events = Array.new(count) do |index|
        {
          message_id: SecureRandom.uuid_v7,
          occurred_at: utc('2026-09-22T00:00:00Z') + index.seconds,
          received_at: received_at,
          external_id: "user_#{index % 7}",
          event: 'tick',
          properties: {},
          context: {}
        }
      end
      ClickMan.store.insert(events)
    end

    test 'raw events become column chunks per day and event, losing nothing' do
      raw('export_completed', external_id: 'user_1', at: utc('2026-09-22T10:00:00.250Z'), properties: { format: 'mp4' }, context: { os: { name: 'iOS' } })
      raw('export_completed', external_id: 'user_2', at: utc('2026-09-22T09:00:00Z'), properties: { format: 'mov', size: 3 })
      raw('export_completed', external_id: 'user_1', at: utc('2026-09-23T08:00:00Z'))
      raw('paywall_viewed', external_id: 'user_1', at: utc('2026-09-22T11:00:00Z'))

      assert_equal 4, ClickMan.rotate!(now: NOW)

      export = ClickMan::EventName.find_by!(name: 'export_completed')
      assert_equal [[day('2026-09-22'), 2], [day('2026-09-23'), 1]], ClickMan::Chunk.where(event_name_id: export.id).order(:day).pluck(:day, :events)
      assert_equal(
        [
          { at: utc('2026-09-22T09:00:00Z'), actor: 'user_2', fields: { 'format' => 'mov', 'size' => 3 } },
          { at: utc('2026-09-22T10:00:00.250Z'), actor: 'user_1', fields: { 'format' => 'mp4', 'context.os.name' => 'iOS' } },
          { at: utc('2026-09-23T08:00:00Z'), actor: 'user_1', fields: {} }
        ],
        chunk_events('export_completed')
      )
    end

    test 'dictionaries fill themselves and actors remember the first day they were seen' do
      raw('a', external_id: 'user_1', at: utc('2026-09-22T10:00:00Z'), properties: { k: 1 }, context: { os: { name: 'iOS' } })

      ClickMan.rotate!(now: NOW)

      assert_equal ['a'], ClickMan::EventName.pluck(:name)
      assert_equal ['context.os.name', 'k'], ClickMan::Key.order(:key).pluck(:key)
      assert_equal day('2026-09-22'), ClickMan::Actor.find_by!(external_id: 'user_1').first_seen_on
    end

    test 'actor days carry one bit per active day and none for the anonymous actor' do
      raw('a', external_id: 'user_1', at: utc('2026-01-01T10:00:00Z'))
      raw('a', external_id: 'user_1', at: utc('2026-09-22T10:00:00Z'))
      raw('b', external_id: 'user_1', at: utc('2026-09-22T11:00:00Z'))
      raw('a', external_id: ClickMan::ANONYMOUS, at: utc('2026-09-22T10:00:00Z'))

      ClickMan.rotate!(now: NOW)

      actor = ClickMan::Actor.find_by!(external_id: 'user_1')
      days = ClickMan::ActorDay.find_by!(actor_id: actor.id, year: 2026).days
      assert_equal 366, days.length
      assert_equal [0, day('2026-09-22').yday - 1], days.chars.each_index.select { days[it] == '1' }
      assert_equal 1, ClickMan::ActorDay.count
    end

    test 'daily counts hold events and identified actors per day and event' do
      raw('a', external_id: 'user_1', at: utc('2026-09-22T10:00:00Z'))
      raw('a', external_id: 'user_1', at: utc('2026-09-22T11:00:00Z'))
      raw('a', external_id: 'user_2', at: utc('2026-09-22T12:00:00Z'))
      raw('a', external_id: ClickMan::ANONYMOUS, at: utc('2026-09-22T13:00:00Z'))

      ClickMan.rotate!(now: NOW)

      count = ClickMan::DailyCount.sole
      assert_equal [day('2026-09-22'), 4, 2], [count.day, count.events, count.actors]
    end

    test 'a late event tops up the last chunk of its day in time order and the counts follow' do
      raw('a', external_id: 'user_1', at: utc('2026-09-20T10:00:00Z'), received_at: utc('2026-09-20T10:00:01Z'))
      ClickMan.rotate!(now: NOW)

      raw('a', external_id: 'user_2', at: utc('2026-09-20T09:00:00Z'), received_at: utc('2026-09-23T11:00:00Z'))
      ClickMan.rotate!(now: NOW)

      assert_equal [[1, 2]], ClickMan::Chunk.where(day: day('2026-09-20')).pluck(:seq, :events)
      assert_equal %w[user_2 user_1], chunk_events('a').pluck(:actor)
      assert_equal [[2, 2]], ClickMan::DailyCount.where(day: day('2026-09-20')).pluck(:events, :actors)
    end

    test 'a full chunk is never rewritten and the next one takes the late events' do
      ticks(4_096, received_at: utc('2026-09-22T23:00:00Z'))
      ClickMan.rotate!(now: NOW)
      full = ClickMan::Chunk.find_by!(seq: 1).payload

      ticks(3, received_at: utc('2026-09-23T10:00:00Z'))
      ClickMan.rotate!(now: NOW)
      ticks(2, received_at: utc('2026-09-23T11:00:00Z'))
      ClickMan.rotate!(now: NOW)

      assert_equal [[1, 4_096], [2, 5]], ClickMan::Chunk.order(:seq).pluck(:seq, :events)
      assert_equal full, ClickMan::Chunk.find_by!(seq: 1).payload
      assert_equal 4_101, ClickMan::DailyCount.sole.events
    end

    test 'a late event moves the first day an actor was seen back' do
      raw('a', external_id: 'user_1', at: utc('2026-09-22T10:00:00Z'), received_at: utc('2026-09-22T10:00:00Z'))
      ClickMan.rotate!(now: NOW)

      raw('a', external_id: 'user_1', at: utc('2026-09-10T10:00:00Z'), received_at: utc('2026-09-23T11:00:00Z'))
      ClickMan.rotate!(now: NOW)

      assert_equal day('2026-09-10'), ClickMan::Actor.find_by!(external_id: 'user_1').first_seen_on
    end

    test 'rotation is idempotent and leaves events younger than the lag for later' do
      raw('a', external_id: 'user_1', at: NOW - 10.minutes)
      raw('a', external_id: 'user_1', at: NOW - 30.seconds)

      assert_equal 1, ClickMan.rotate!(now: NOW)
      assert_equal 0, ClickMan.rotate!(now: NOW)
      assert_equal 1, ClickMan.rotate!(now: NOW + 5.minutes)
      assert_equal 2, ClickMan::DailyCount.sole.events
    end

    test 'large days are cut into chunks of at most 4096 events' do
      ticks(4_100, received_at: utc('2026-09-22T23:00:00Z'))

      ClickMan.rotate!(now: NOW)

      assert_equal [4_096, 4], ClickMan::Chunk.order(:seq).pluck(:events)
    end

    if ClickManTestDatabase.postgres?
      test 'chunks live in monthly partitions' do
        raw('a', external_id: 'user_1', at: utc('2026-08-31T23:59:59Z'))
        raw('a', external_id: 'user_1', at: utc('2026-09-01T00:00:00Z'))

        ClickMan.rotate!(now: NOW)

        partitions = ClickMan::Record.connection.select_values(<<~SQL)
          SELECT child.relname FROM pg_inherits
          JOIN pg_class parent ON parent.oid = inhparent
          JOIN pg_class child ON child.oid = inhrelid
          WHERE parent.relname = 'clickman_chunks' ORDER BY 1
        SQL
        assert_equal %w[clickman_chunks_2026_08 clickman_chunks_2026_09], partitions
      end
    end
  end
end
