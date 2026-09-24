module ClickMan
  class Record < ActiveRecord::Base
    self.abstract_class = true

    if (database = ClickMan.configuration.database)
      connects_to database: { writing: database, reading: database }
    end
  end
end
