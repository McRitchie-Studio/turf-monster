// Registers the dev score tools' controller on the engine's Stimulus application (Turf's controllers share it; see turf_stimulus).
//
// live/_dev_score_tools imports this from its own module tag, so the controller
// is connected by the time the page has loaded and a press straight after a
// load is never lost. Only a page that renders the tools fetches it, and no
// production page does.
import { application } from "turf_stimulus"
import DevScoreToolsController from "controllers/dev_score_tools_controller"

application.register("dev-score-tools", DevScoreToolsController)
