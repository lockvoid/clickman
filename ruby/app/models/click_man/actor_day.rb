module ClickMan
  class ActorDay < Record
    self.primary_key = %w[actor_id year]

    belongs_to :actor
  end
end
