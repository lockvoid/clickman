require 'test_helper'

module ClickMan
  class PruningTest < ActiveSupport::TestCase
    NOW = Time.iso8601('2026-09-23T12:00:00Z')

    test 'rotated raw events leave once the deduplication window has passed' do
      raw('old', external_id: 'user_1', at: NOW - 8.days)
      raw('fresh', external_id: 'user_1', at: NOW - 6.days)
      ClickMan.rotate!(now: NOW)

      ClickMan.prune!(now: NOW)

      assert_equal ['fresh'], ClickMan::Event.pluck(:event)
      assert_equal 2, ClickMan::DailyCount.sum(:events), 'chunks keep everything'
    end

    test 'raw events not yet rotated are never pruned' do
      raw('old', external_id: 'user_1', at: NOW - 8.days)

      ClickMan.prune!(now: NOW)

      assert_equal ['old'], ClickMan::Event.pluck(:event)
    end

    test 'raw events a destination has not received yet are kept' do
      ClickMan.configure { it.destinations = [RecordingDestination.new] }
      raw('old', external_id: 'user_1', at: NOW - 8.days)
      ClickMan.rotate!(now: NOW)

      ClickMan.prune!(now: NOW)
      assert_equal 1, ClickMan::Event.count

      ClickMan.deliver!(now: NOW)
      ClickMan.prune!(now: NOW)
      assert_equal 0, ClickMan::Event.count
    end

    test 'retention drops whole months of chunks and their counts' do
      ClickMan.configure { it.retention = 60.days }
      raw('ancient', external_id: 'user_1', at: utc('2026-06-15T10:00:00Z'))
      raw('recent', external_id: 'user_1', at: utc('2026-09-01T10:00:00Z'))
      ClickMan.rotate!(now: NOW)

      ClickMan.prune!(now: NOW)

      assert_equal [day('2026-09-01')], ClickMan::Chunk.pluck(:day)
      assert_equal [day('2026-09-01')], ClickMan::DailyCount.pluck(:day)
    end

    test 'retention forgets the active days of the months it drops' do
      ClickMan.configure { it.retention = 60.days }
      raw('ancient', external_id: 'user_1', at: utc('2026-06-15T10:00:00Z'))
      raw('recent', external_id: 'user_1', at: utc('2026-09-01T10:00:00Z'))
      raw('ancient', external_id: 'user_2', at: utc('2025-12-31T10:00:00Z'))
      ClickMan.rotate!(now: NOW)

      ClickMan.prune!(now: NOW)

      actor = ClickMan::Actor.find_by!(external_id: 'user_1')
      days = ClickMan::ActorDay.find_by!(actor_id: actor.id, year: 2026).days
      assert_equal [day('2026-09-01').yday - 1], days.chars.each_index.select { days[it] == '1' }
      assert_equal 1, ClickMan::ActorDay.count
    end

    test 'erasing an actor removes them from raw events, chunks, bits and counts' do
      raw('a', external_id: 'user_1', at: utc('2026-09-22T10:00:00Z'))
      raw('a', external_id: 'user_2', at: utc('2026-09-22T11:00:00Z'))
      raw('b', external_id: 'user_1', at: utc('2026-09-21T11:00:00Z'))
      ClickMan.rotate!(now: NOW)
      actor = ClickMan::Actor.find_by!(external_id: 'user_1')

      ClickMan.erase!('user_1')

      assert_equal ['user_2'], ClickMan::Event.pluck(:external_id)
      remaining_actors = ClickMan::Chunk.all.flat_map { ClickMan::Columns.decode(it.payload)[:actors] }
      assert_not_includes remaining_actors, actor.id
      assert_equal 0, ClickMan::ActorDay.where(actor_id: actor.id).count
      assert_nil ClickMan::Actor.find_by(external_id: 'user_1')
      assert actor.reload.erased_at
      assert_equal [[day('2026-09-22'), 1, 1]], ClickMan::DailyCount.order(:day).pluck(:day, :events, :actors)
    end

    test 'the anonymous actor cannot be erased' do
      assert_raises(ArgumentError) { ClickMan.erase!(ClickMan::ANONYMOUS) }
    end
  end
end
