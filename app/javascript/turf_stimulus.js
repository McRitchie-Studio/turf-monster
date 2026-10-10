// Turf's own Stimulus application, on Stimulus' own attributes (data-controller,
// data-action, data-<name>-target). The engine's controllers run on a separate
// application, on data-studio-controller.
//
// "@hotwired/stimulus" is the engine's vendored copy (the engine pins it), so
// the two applications share one Stimulus.
//
// Two ways a controller registers:
//
//   - imported below and registered at once. It is connected before the page
//     has loaded, so its first press is never lost. Every page fetches it.
//   - listed in LAZY and registered the first time an element names it, so
//     only a page that uses it fetches it. Until it registers, its element's
//     actions do nothing, and its markup carries the initial state (hidden,
//     disabled). A controller whose module fails to load marks its elements
//     data-controller-failed="<identifier>".
//
// config/importmap.rb preloads what is imported here and nothing that is lazy.
import { Application } from "@hotwired/stimulus"
import { watchLazyControllers } from "studio/lazy_controllers"
import DevScoreToolsController from "controllers/dev_score_tools_controller"
import FilterController from "controllers/filter_controller"
import GameScorerController from "controllers/game_scorer_controller"
import HubActionsController from "controllers/hub_actions_controller"
import ScoringFilterController from "controllers/scoring_filter_controller"
import SendGateController from "controllers/send_gate_controller"
import ShowMoreController from "controllers/show_more_controller"

export const LAZY = {
  "seeds-lab": () => import("controllers/seeds_lab_controller"),
  "toast-demo": () => import("controllers/toast_demo_controller")
}

export const application = Application.start()

application.register("dev-score-tools", DevScoreToolsController)
application.register("filter", FilterController)
application.register("game-scorer", GameScorerController)
application.register("hub-actions", HubActionsController)
application.register("scoring-filter", ScoringFilterController)
application.register("send-gate", SendGateController)
application.register("show-more", ShowMoreController)

export const lazy = watchLazyControllers({
  root: document.documentElement,
  attribute: "data-controller",
  failedAttribute: "data-controller-failed",
  loaders: LAZY,
  register: (name, controller) => application.register(name, controller)
})
