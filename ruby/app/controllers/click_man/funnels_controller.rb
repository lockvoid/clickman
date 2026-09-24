module ClickMan
  class FunnelsController < ApplicationController
    def show
      @funnel = Funnel.load(ClickMan.configuration.funnels_path).find { it.key == params[:key] }
      return head :not_found unless @funnel

      @report = Report.find_by(key: "#{Reports::FUNNEL_PREFIX}#{@funnel.key}")
    end
  end
end
