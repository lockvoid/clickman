module ClickMan
  class Reports
    ACTIVES_DAYS = 90
    COHORT_DAYS = 90
    EVENTS_DAYS = 30
    FUNNEL_PREFIX = 'funnel:'.freeze

    def initialize(store:, funnels:)
      @store = store
      @funnels = funnels
    end

    def refresh!(now:)
      today = now.utc.to_date

      save('actives', { 'days' => @store.actives(from: today - (ACTIVES_DAYS - 1), to: today) }, now)
      save('retention', { 'cohorts' => cohorts(today) }, now)
      save('events', { 'events' => @store.event_totals(from: today - (EVENTS_DAYS - 1), to: today) }, now)
      @funnels.each { save("#{FUNNEL_PREFIX}#{it.key}", it.compute(store: @store, now: now), now) }

      Report.where('key LIKE ?', "#{FUNNEL_PREFIX}%").where.not(key: @funnels.map { "#{FUNNEL_PREFIX}#{it.key}" }).delete_all
    end

    private

      def cohorts(today)
        @store.cohorts(from: today - (COHORT_DAYS - 1), to: today).map do |cohort|
          unreached = Store::RETURN_DAYS.select { Date.iso8601(cohort['day']) + it > today }
          cohort.merge(unreached.to_h { ["d#{it}", nil] })
        end
      end

      def save(key, result, now)
        Report.upsert({ key: key, result: result, computed_at: now }, unique_by: :key)
      end
  end
end
