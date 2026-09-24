module ClickMan
  module Stores
    class Relational < Store
      ROTATION_PAGE = 20_000
      PRUNE_BATCH = 10_000
      READ_BATCH = 64
      WEEK = 7
      MONTH = 30
      PENDING_COLUMNS = %i[message_id occurred_at received_at external_id event properties context].freeze
      CHUNK_KEY = %i[day event_name_id seq].freeze

      Row = Data.define(:millisecond, :actor, :fields)

      def insert(events)
        Event.insert_all(events, unique_by: :message_id) if events.any?
      end

      def rotate!(now:, lag:)
        cutoff = now - lag
        rotated = 0

        loop do
          page = Record.transaction do
            next 0 unless try_lock

            rotate_page(cutoff)
          end
          rotated += page
          break if page < ROTATION_PAGE
        end

        rotated
      end

      def prune!(now:, dedup_window:, retention:, holds:)
        passed = slowest_cursor([ROTATION_CURSOR, *holds])
        delete_raw(before: now - dedup_window, through: passed) if passed
        return unless retention

        Record.transaction do
          lock
          drop_months_before((now - retention).utc.to_date.beginning_of_month)
        end
      end

      def erase!(external_id, now:)
        raise ArgumentError, 'the anonymous actor cannot be erased' if external_id == ANONYMOUS

        Record.transaction do
          lock
          Event.where(external_id: external_id).delete_all
          actor = Actor.find_by(external_id: external_id)
          forget(actor, now) if actor
        end
      end

      def pending(cursor:, before:, limit:)
        scope = Event.where(received_at: ..before).order(:received_at, :message_id).limit(limit)
        position = Cursor.find_by(name: cursor)
        scope = scope.where('(received_at, message_id) > (?, ?)', position.received_at, position.message_id) if position
        scope.pluck(*PENDING_COLUMNS).map { PENDING_COLUMNS.zip(it).to_h }
      end

      def advance!(cursor:, to:)
        Cursor.upsert({ name: cursor, received_at: to[:received_at], message_id: to[:message_id] }, unique_by: :name)
      end

      def actives(from:, to:)
        start = from - (MONTH - 1)
        size = (to - start).to_i + 1
        daily = Array.new(size, 0)
        weekly = Array.new(size + 1, 0)
        monthly = Array.new(size + 1, 0)

        active_offsets(start, to).each_value do |offsets|
          offsets.each { daily[it] += 1 }
          spread(weekly, offsets, WEEK)
          spread(monthly, offsets, MONTH)
        end

        weekly = running_sums(weekly)
        monthly = running_sums(monthly)
        (from..to).map do |day|
          index = (day - start).to_i
          { 'day' => day.iso8601, 'dau' => daily[index], 'wau' => weekly[index], 'mau' => monthly[index] }
        end
      end

      def cohorts(from:, to:)
        Record.lease_connection.select_rows(Record.sanitize_sql([cohorts_sql, ANONYMOUS, from, to])).map do |day, size, *returned|
          { 'day' => day.to_s, 'size' => size }.merge(RETURN_DAYS.zip(returned).to_h { |days, actors| ["d#{days}", actors.to_i] })
        end
      end

      def event_totals(from:, to:)
        events = DailyCount.where(day: from..to).group(:event_name_id).sum(:events)
        names = EventName.where(id: events.keys).pluck(:id, :name).to_h
        actors = Hash.new { |hash, key| hash[key] = Set.new }
        anonymous = anonymous_actor

        Chunk.where(day: from..to).select(*CHUNK_KEY, :payload).find_each(batch_size: READ_BATCH) do |chunk|
          actors[chunk.event_name_id].merge(Columns.actors(chunk.payload))
        end

        totals = events.map do |event_name_id, count|
          { 'event' => names.fetch(event_name_id), 'events' => count, 'actors' => (actors[event_name_id] - [anonymous]).size }
        end
        totals.sort_by { [-it['events'], it['event']] }
      end

      def each_event(names:, from:, to:, keys:)
        event_names = EventName.where(name: names).pluck(:id, :name).to_h
        key_names = Key.where(key: keys).pluck(:id, :key).to_h
        anonymous = anonymous_actor

        Chunk.where(event_name_id: event_names.keys, day: from..to).find_each(batch_size: READ_BATCH) do |chunk|
          start = epoch_millisecond(chunk.day)
          event = event_names.fetch(chunk.event_name_id)

          rows_of(chunk.payload).each do |row|
            next if row.actor == anonymous

            fields = row.fields.filter_map { |key_id, value| [key_names[key_id], value] if key_names.key?(key_id) }.to_h
            yield Occurrence.new(at: start + row.millisecond, actor: row.actor, event: event, fields: fields)
          end
        end
      end

      private

        def rotate_page(cutoff)
          events = pending(cursor: ROTATION_CURSOR, before: cutoff, limit: ROTATION_PAGE)
          return 0 if events.empty?

          names = dictionary(EventName, :name, events.map { it[:event] })
          keys = dictionary(Key, :key, events.flat_map { fields_of(it).keys })
          actors = actors_for(events)

          touched = events.group_by { [day_of(it[:occurred_at]), names.fetch(it[:event])] }.map do |(day, event_name_id), group|
            append(day, event_name_id, group.map { row_for(it, day, actors, keys) })
            [day, event_name_id]
          end

          mark_active_days(events, actors)
          recount(touched)
          advance!(cursor: ROTATION_CURSOR, to: events.last)
          events.size
        end

        def dictionary(model, column, values)
          values = values.uniq
          missing = values - model.where(column => values).pluck(column)
          model.insert_all(missing.map { { column => it } }, unique_by: column) if missing.any?
          model.where(column => values).pluck(column, :id).to_h
        end

        def actors_for(events)
          first_days = events.group_by { it[:external_id] }.transform_values do |group|
            group.map { day_of(it[:occurred_at]) }.min
          end
          known = Actor.where(external_id: first_days.keys).pluck(:external_id, :id, :first_seen_on)

          known.each do |external_id, id, first_seen_on|
            Actor.where(id: id).update_all(first_seen_on: first_days[external_id]) if first_days[external_id] < first_seen_on
          end

          missing = first_days.keys - known.map(&:first)
          Actor.insert_all(missing.map { { external_id: it, first_seen_on: first_days[it] } }) if missing.any?
          Actor.where(external_id: first_days.keys).pluck(:external_id, :id).to_h
        end

        def fields_of(event)
          event[:properties].merge(event[:context].transform_keys { "context.#{it}" }).compact
        end

        def row_for(event, day, actors, keys)
          Row.new(
            millisecond: millisecond_of(event[:occurred_at], day),
            actor: actors.fetch(event[:external_id]),
            fields: fields_of(event).transform_keys { keys.fetch(it) }
          )
        end

        def append(day, event_name_id, rows)
          last_seq, last_events = Chunk.where(day: day, event_name_id: event_name_id).order(seq: :desc).pick(:seq, :events)
          seq = last_seq ? last_seq + 1 : 1

          if last_seq && last_events < CHUNK_EVENTS
            seq = last_seq
            rows = rows_of(Chunk.where(day: day, event_name_id: event_name_id, seq: seq).pick(:payload)) + rows
          end

          ensure_partition(day)
          chunks = in_time_order(rows).each_slice(CHUNK_EVENTS).with_index(seq).map do |slice, number|
            chunk_attributes(day, event_name_id, number, slice)
          end
          Chunk.upsert_all(chunks, unique_by: CHUNK_KEY)
        end

        def in_time_order(rows)
          rows.sort_by.with_index { |row, index| [row.millisecond, index] }
        end

        def chunk_attributes(day, event_name_id, seq, rows)
          key_ids = rows.flat_map { it.fields.keys }.uniq.sort
          payload = Columns.encode(
            times: rows.map(&:millisecond),
            actors: rows.map(&:actor),
            columns: key_ids.to_h { |key_id| [key_id, rows.map { it.fields[key_id] }] }
          )

          { day: day, event_name_id: event_name_id, seq: seq, events: rows.size, key_ids: key_ids, payload: payload }
        end

        def rows_of(payload)
          decoded = Columns.decode(payload)

          decoded[:times].each_index.map do |index|
            fields = decoded[:columns].filter_map { |key_id, values| [key_id, values[index]] unless values[index].nil? }
            Row.new(millisecond: decoded[:times][index], actor: decoded[:actors][index], fields: fields.to_h)
          end
        end

        def mark_active_days(events, actors)
          anonymous = actors[ANONYMOUS]
          years = Hash.new { |hash, key| hash[key] = '0' * 366 }

          events.each do |event|
            actor = actors.fetch(event[:external_id])
            next if actor == anonymous

            day = day_of(event[:occurred_at])
            years[[actor, day.year]][day.yday - 1] = '1'
          end

          merge_active_days(years) if years.any?
        end

        def recount(pairs)
          anonymous = anonymous_actor

          pairs.each do |day, event_name_id|
            chunks = Chunk.where(day: day, event_name_id: event_name_id).pluck(:events, :payload)

            if chunks.empty?
              DailyCount.where(day: day, event_name_id: event_name_id).delete_all
            else
              actors = chunks.flat_map { Columns.actors(it.last) }.uniq - [anonymous]
              DailyCount.upsert(
                { day: day, event_name_id: event_name_id, events: chunks.sum(&:first), actors: actors.size },
                unique_by: %i[day event_name_id]
              )
            end
          end
        end

        def slowest_cursor(names)
          positions = Cursor.where(name: names).pluck(:received_at, :message_id)
          positions.min if positions.size == names.uniq.size
        end

        def delete_raw(before:, through:)
          expired = Event.where(received_at: ...before).where('(received_at, message_id) <= (?, ?)', *through)

          loop do
            deleted = Event.where(message_id: expired.limit(PRUNE_BATCH).select(:message_id)).delete_all
            break if deleted < PRUNE_BATCH
          end
        end

        def forget(actor, now)
          touched = []

          Chunk.where(day: active_days(actor.id)).find_each(batch_size: READ_BATCH) do |chunk|
            rows = rows_of(chunk.payload)
            kept = rows.reject { it.actor == actor.id }
            next if kept.size == rows.size

            if kept.empty?
              chunk.delete
            else
              Chunk.upsert(chunk_attributes(chunk.day, chunk.event_name_id, chunk.seq, kept), unique_by: CHUNK_KEY)
            end
            touched << [chunk.day, chunk.event_name_id]
          end

          recount(touched.uniq)
          ActorDay.where(actor_id: actor.id).delete_all
          actor.update!(external_id: nil, erased_at: now)
        end

        def active_days(actor_id)
          ActorDay.where(actor_id: actor_id).flat_map do |actor_day|
            january_first = Date.new(actor_day.year, 1, 1)
            set_bits(actor_day.days).map { january_first + it }
          end
        end

        def active_offsets(from, to)
          offsets = Hash.new { |hash, key| hash[key] = [] }

          (from.year..to.year).each do |year|
            first = [from, Date.new(year, 1, 1)].max
            last = [to, Date.new(year, 12, 31)].min
            window, active = bits_window(first.yday, (last - first).to_i + 1)
            base = (first - from).to_i

            ActorDay.joins(:actor).merge(Actor.identified).where(year: year).where(active)
                    .pluck(:actor_id, Arel.sql(window))
                    .each { |actor_id, bits| offsets[actor_id].concat(set_bits(bits).map { base + it }) }
          end

          offsets
        end

        def set_bits(bits)
          indexes = []
          index = bits.index('1')

          while index
            indexes << index
            index = bits.index('1', index + 1)
          end

          indexes
        end

        def spread(difference, offsets, width)
          covered = -1

          offsets.each do |offset|
            first = [offset, covered + 1].max
            last = [offset + width - 1, difference.size - 2].min
            next if first > last

            difference[first] += 1
            difference[last + 1] -= 1
            covered = last
          end
        end

        def running_sums(difference)
          total = 0
          difference.map { total += it }
        end

        def anonymous_actor
          Actor.where(external_id: ANONYMOUS).pick(:id)
        end

        def day_of(time)
          time.utc.to_date
        end

        def millisecond_of(time, day)
          (time.to_r * 1000).floor - epoch_millisecond(day)
        end

        def epoch_millisecond(day)
          Time.utc(day.year, day.month, day.day).to_i * 1000
        end
    end
  end
end
