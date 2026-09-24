ClickMan::Engine.routes.draw do
  root to: 'dashboard#show'
  get 'funnels/:key', to: 'funnels#show', as: :funnel
end
