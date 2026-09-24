module ClickMan
  module Stores
    def self.for(adapter)
      case adapter.to_s
      when /postg/i
        Postgres.new
      when /sqlite/i
        SQLite.new
      else
        raise Error, "ClickMan has no store for the #{adapter} adapter"
      end
    end
  end
end
