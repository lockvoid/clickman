module ClickMan
  module Stores
    class SQLite < Relational
      YEAR_BITS = 366

      private

        def try_lock
          true
        end

        def lock
        end

        def ensure_partition(_day)
        end

        def merge_active_days(years)
          stored = ActorDay.where(actor_id: years.keys.map(&:first).uniq, year: years.keys.map(&:last).uniq)
                           .pluck(:actor_id, :year, :days)
                           .to_h { |actor_id, year, days| [[actor_id, year], days] }

          ActorDay.upsert_all(
            years.map do |(actor_id, year), days|
              merged = stored.key?([actor_id, year]) ? bits(stored[[actor_id, year]].to_i(2) | days.to_i(2)) : days
              { actor_id: actor_id, year: year, days: merged }
            end,
            unique_by: %i[actor_id year]
          )
        end

        def bits_window(first_day, length)
          window = "substr(clickman_actor_days.days, #{first_day}, #{length})"
          [window, "instr(#{window}, '1') > 0"]
        end

        def cohorts_sql
          returns = RETURN_DAYS.map do |days|
            [
              "LEFT JOIN clickman_actor_days d#{days} " \
              "ON d#{days}.actor_id = a.id AND d#{days}.year = CAST(strftime('%Y', a.first_seen_on, '+#{days} day') AS integer)",
              "sum(CASE WHEN substr(d#{days}.days, CAST(strftime('%j', a.first_seen_on, '+#{days} day') AS integer), 1) = '1' " \
              'THEN 1 ELSE 0 END)'
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
          Chunk.where(day: ...month).delete_all
          DailyCount.where(day: ...month).delete_all
          ActorDay.where(year: ...month.year).delete_all

          kept_from = month.yday - 1
          return if kept_from.zero?

          mask = (('0' * kept_from) + ('1' * (YEAR_BITS - kept_from))).to_i(2)
          ActorDay.where(year: month.year).find_each do |actor_day|
            kept = actor_day.days.to_i(2) & mask
            if kept.zero?
              actor_day.delete
            else
              actor_day.update_columns(days: bits(kept))
            end
          end
        end

        def bits(number)
          number.to_s(2).rjust(YEAR_BITS, '0')
        end
    end
  end
end
