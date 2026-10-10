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
//   - STATIC, for a controller on a public page, or one a player presses the
//     moment a page loads: import it here and application.register it below.
//     Add its module, and the modules it imports, to every_page in
//     config/importmap.rb, so every page preloads them and the controller is
//     connected before the page has loaded, on a full load and on a Turbo
//     visit alike. A lazy controller drops a press made before its module
//     arrives; a static one never does. Its markup still renders the safe
//     state, so nothing is pressable that would do the wrong thing.
//   - A PAGE'S OWN MODULE TAG, for a page-specific controller that is pressed
//     the moment its page loads: the view imports a small module that
//     registers it (dev_tools, from live/_dev_score_tools), with
//     javascript_import_module_tag. It is connected before the page has
//     loaded, and only that page fetches it.
import { Application } from "@hotwired/stimulus"
import { watchLazyControllers } from "studio/lazy_controllers"
import AccordionController from "controllers/accordion_controller"
import AutoSubmitController from "controllers/auto_submit_controller"
import CardFilterController from "controllers/card_filter_controller"
import CostCalculatorController from "controllers/cost_calculator_controller"
import ProofOfReservesController from "controllers/proof_of_reserves_controller"
import SwatchCopyController from "controllers/swatch_copy_controller"

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

application.register("accordion", AccordionController)
application.register("auto-submit", AutoSubmitController)
application.register("card-filter", CardFilterController)
application.register("cost-calculator", CostCalculatorController)
application.register("proof-of-reserves", ProofOfReservesController)
application.register("swatch-copy", SwatchCopyController)

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
