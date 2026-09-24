module ClickMan
  class DashboardController < ApplicationController
    def show
      reports = Report.where(key: %w[actives events retention]).index_by(&:key)
      @actives = reports['actives']
      @events = reports['events']
      @retention = reports['retention']

      @funnels = Funnel.load(ClickMan.configuration.funnels_path)
      funnel_reports = Report.where(key: @funnels.map { "#{Reports::FUNNEL_PREFIX}#{it.key}" })
      @funnel_steps = funnel_reports.to_h { [it.key.delete_prefix(Reports::FUNNEL_PREFIX), it.result['steps']] }
    end
  end
end
