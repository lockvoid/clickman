module ClickMan
  class Chunk < Record
    self.primary_key = %w[day event_name_id seq]
  end
end
