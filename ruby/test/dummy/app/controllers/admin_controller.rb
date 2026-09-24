class AdminController < ActionController::Base
  before_action do
    head :forbidden unless request.headers['X-Admin'] == 'yes'
  end
end
