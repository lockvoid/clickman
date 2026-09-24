module ClickMan
  class DailyCount < Record
    self.primary_key = %w[day event_name_id]
  end
end
