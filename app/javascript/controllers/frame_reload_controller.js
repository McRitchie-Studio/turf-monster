import { Controller } from "@hotwired/stimulus"
import { reloadPlan } from "turf/frame_reload"

// Makes the closest turbo-frame fetch itself again, so the server re-decides
// what it shows. Bind reload to the window event that means the answer changed
// (age-verified@window). A frame rendered inline gets `src` as its src.
export default class extends Controller {
  static values = { src: String }

  reload() {
    const frame = this.element.closest("turbo-frame")
    if (!frame) return
    const plan = reloadPlan(frame.src, this.srcValue)
    if (plan.reload) frame.reload()
    else frame.src = plan.src
  }
}
