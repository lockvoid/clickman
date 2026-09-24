module ClickMan
  class Actor < Record
    scope :identified, -> { where(erased_at: nil).where.not(external_id: ANONYMOUS) }
  end
end
