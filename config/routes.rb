Rails.application.routes.draw do
  # Unauthenticated liveness probe for the hosting platform.
  get "up" => "rails/health#show", as: :rails_health_check

  root "root#show"

  namespace :api do
    namespace :v1 do
      get "profile", to: "profiles#show"
      get "health",  to: "health#show"
    end
  end
end
