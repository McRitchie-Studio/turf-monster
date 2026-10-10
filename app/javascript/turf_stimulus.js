// Turf's own Stimulus application, on Stimulus' own attributes (data-controller,
// data-action, data-<name>-target). The engine's controllers run on a separate
// application, on data-studio-controller.
//
// "@hotwired/stimulus" is the engine's vendored copy (the engine pins it), so
// the two applications share one Stimulus.
//
// Three ways a controller registers:
//
//   - LAZY, for a controller only some pages use (every admin and dev tool):
//     it is fetched and registered the first time an element names it, so no
//     other page pays for it. Until it registers, its element's actions do
//     nothing and its markup carries the initial state (hidden, disabled). The
//     root element lists the registered ones in data-lazy-controllers, which a
//     test waits on before it presses. A controller whose module fails to load
//     marks its elements data-controller-failed="<identifier>".
//   - STATIC, for a controller on every page or one a player presses the
//     moment a page loads: import it here and application.register it below.
//     It is connected before the page has loaded. Add its module, and the
//     modules it imports, to every_page in config/importmap.rb.
//   - A PAGE'S OWN MODULE TAG, for a page-specific controller that is pressed
//     the moment its page loads: the view imports a small module that
//     registers it (dev_tools, from live/_dev_score_tools), with
//     javascript_import_module_tag. It is connected before the page has
//     loaded, and only that page fetches it.
import { Application } from "@hotwired/stimulus"
import { watchLazyControllers } from "studio/lazy_controllers"

export const LAZY = {
  "filter": () => import("controllers/filter_controller"),
  "game-scorer": () => import("controllers/game_scorer_controller"),
  "hub-actions": () => import("controllers/hub_actions_controller"),
  "navbar-preview": () => import("controllers/navbar_preview_controller"),
  "scoring-filter": () => import("controllers/scoring_filter_controller"),
  "seeds-lab": () => import("controllers/seeds_lab_controller"),
  "send-gate": () => import("controllers/send_gate_controller"),
  "show-more": () => import("controllers/show_more_controller"),
  "toast-demo": () => import("controllers/toast_demo_controller")
}

export const application = Application.start()

const registered = []

export const lazy = watchLazyControllers({
  root: document.documentElement,
  attribute: "data-controller",
  failedAttribute: "data-controller-failed",
  loaders: LAZY,
  register: (name, controller) => {
    application.register(name, controller)
    registered.push(name)
    document.documentElement.setAttribute("data-lazy-controllers", registered.join(" "))
  }
})
