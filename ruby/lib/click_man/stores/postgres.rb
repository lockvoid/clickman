require 'zlib'

module ClickMan
  module Stores
    class Postgres < Relational
      LOCK = Zlib.crc32('clickman')

      private

        def try_lock
          Record.lease_connection.select_value("SELECT pg_try_advisory_xact_lock(#{LOCK})")
        end

        def lock
          Record.lease_connection.execute("SELECT pg_advisory_xact_lock(#{LOCK})")
        end

        def ensure_partition(day)
          month = day.beginning_of_month
          @partitions ||= Set.new
          return if @partitions.include?(month)

          name = partition_name(month)
          unless Record.lease_connection.table_exists?(name)
            Record.lease_connection.execute(<<~SQL)
              CREATE TABLE #{name} PARTITION OF clickman_chunks
                FOR VALUES FROM ('#{month.iso8601}') TO ('#{month.next_month.iso8601}')
            SQL
          end
          @partitions << month
        end

        def partition_name(month)
          "clickman_chunks_#{month.strftime('%Y_%m')}"
        end

        def merge_active_days(years)
          ActorDay.upsert_all(
            years.map { |(actor_id, year), days| { actor_id: actor_id, year: year, days: days } },
            unique_by: %i[actor_id year],
            on_duplicate: Arel.sql('days = clickman_actor_days.days | EXCLUDED.days')
          )
        end

        def bits_window(first_day, length)
          window = "substring(clickman_actor_days.days FROM #{first_day} FOR #{length})"
          ["#{window}::text", "bit_count(#{window}) > 0"]
        end

        def cohorts_sql
          returns = RETURN_DAYS.map do |days|
            [
              "LEFT JOIN clickman_actor_days d#{days} " \
              "ON d#{days}.actor_id = a.id AND d#{days}.year = extract(year FROM a.first_seen_on + #{days})",
              "count(*) FILTER (WHERE get_bit(d#{days}.days, extract(doy FROM a.first_seen_on + #{days})::int - 1) = 1)"
            ]
          end

          <<~SQL
            SELECT a.first_seen_on, count(*), #{returns.map(&:last).join(', ')}
            FROM clickman_actors a
            #{returns.map(&:first).join("\n")}
            WHERE a.erased_at IS NULL AND a.external_id <> ? AND a.first_seen_on BETWEEN ? AND ?
            GROUP BY a.first_seen_on
            ORDER BY a.first_seen_on
          SQL
        end

        def drop_months_before(month)
          partitions_before(month).each { Record.lease_connection.execute("DROP TABLE #{it}") }
          DailyCount.where(day: ...month).delete_all
          ActorDay.where(year: ...month.year).delete_all

          kept_from = month.yday - 1
          if kept_from.positive?
            mask = ('0' * kept_from) + ('1' * (366 - kept_from))
            ActorDay.where(year: month.year).update_all(['days = days & ?::varbit', mask])
          end
          ActorDay.where('bit_count(days) = 0').delete_all
        end

        def partitions_before(month)
          names = Record.lease_connection.select_values(<<~SQL)
            SELECT child.relname FROM pg_inherits
            JOIN pg_class child ON child.oid = pg_inherits.inhrelid
            WHERE pg_inherits.inhparent = 'clickman_chunks'::regclass
          SQL
          names.select { Date.strptime(it.delete_prefix('clickman_chunks_'), '%Y_%m') < month }
        end
    end
  end
end
