module ClickMan
  class RotationJob < ActiveJob::Base
    def perform
      ClickMan.rotate!
      ClickMan.prune!
      ClickMan.refresh_reports!
    end
  end
end
