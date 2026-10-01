# The root of the versioned agent API (docs/AGENT_API.md).
#
# ActionController::API, NOT ApplicationController, and that choice is the
# point: ApplicationController is a browser stack — `allow_browser`, CSRF, the
# cookie session and its token check, geo detection off the request IP, the
# profile-completion redirect, navbar preloads. None of it applies to a bearer
# client and several pieces would refuse one outright. Starting from the API
# base means a new before_action added to ApplicationController can never
# silently start applying here.
#
# Everything this surface needs is in ApiKeyAuthentication.
module Api
  module V1
    class BaseController < ActionController::API
      include ApiKeyAuthentication
    end
  end
end
