// Turf's own Stimulus application, on Stimulus' own attributes (data-controller,
// data-action, data-<name>-target). The engine's controllers run on a separate
// application, on data-studio-controller.
//
// "@hotwired/stimulus" is the engine's vendored copy (the engine pins it), so
// the two applications share one Stimulus.
//
// A page-specific controller is listed in LAZY and registered the first time
// an element names it, so only a page that uses it fetches it. Until it
// registers, its element's actions do nothing: the markup carries the initial
// state (the hidden attribute, disabled). A controller whose module fails to
// load marks its elements data-controller-failed="<identifier>".
//
// An every-page controller is imported and registered here, statically.
import { Application } from "@hotwired/stimulus"
import { watchLazyControllers } from "studio/lazy_controllers"

export const LAZY = {
  "dev-score-tools": () => import("controllers/dev_score_tools_controller"),
  "filter": () => import("controllers/filter_controller"),
  "hub-actions": () => import("controllers/hub_actions_controller"),
  "seeds-lab": () => import("controllers/seeds_lab_controller"),
  "send-gate": () => import("controllers/send_gate_controller"),
  "show-more": () => import("controllers/show_more_controller"),
  "toast-demo": () => import("controllers/toast_demo_controller")
}

export const application = Application.start()

export const lazy = watchLazyControllers({
  root: document.documentElement,
  attribute: "data-controller",
  failedAttribute: "data-controller-failed",
  loaders: LAZY,
  register: (name, controller) => application.register(name, controller)
})
