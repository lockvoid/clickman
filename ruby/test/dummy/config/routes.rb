Rails.application.routes.draw do
  mount ClickMan::Engine, at: '/analytics'
end
