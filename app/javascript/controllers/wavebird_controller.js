import { Controller } from "@hotwired/stimulus";

// Decorates a wavebird sponsor slot `<section>` (rendered by the
// `wavebird_slot` view helper) with the browser glue for the hosted renderer.
//
// The hosted `render.js` OWNS the slot element: given the turn, it POSTs to the
// slot's `data-wavebird-endpoint`, reveals the `<section>` on fill (mounting the
// iframe via `replaceChildren` + `hidden = false`), and keeps it hidden on
// no-fill or error. This controller therefore does NOT fetch, parse a response,
// or toggle the element — it only:
//
//   1. loads `/v1/render.js` once per page (idempotent), degrading silently if
//      it never loads, and
//   2. bridges the host's chat turn into `window.wavebird.withTurn(...)`.
//
// Two host entry points, both funnelling into the same `withTurn` call
// (decision #008):
//
//   Path C — faithful upstream global: the host calls
//     `window.wavebird.withTurn('#wavebird-slot-below', work)` directly, exactly
//     per the integration brief. Works once render.js is loaded; needs nothing
//     from this controller beyond the script tag.
//
//   Path A — Stimulus-idiomatic bridge: the host dispatches a `wavebird:turn`
//     CustomEvent (on the slot element or a descendant) carrying `detail.work`,
//     the function that runs the AI turn. This controller wraps it in
//     `withTurn`, injecting the stable `session_id` as the explicit request body
//     (render.js's own default body is just a random uuid, so path C alone can
//     not carry our session id). If `window.wavebird` is unavailable, it runs
//     `detail.work()` unwrapped so the chat turn is never blocked.
export default class extends Controller {
  static targets = ["signal"];

  static values = {
    sessionId: String,
    position: String,
    // Set by the view helper when the slot was rendered with `async: true`, to
    // request async delivery. Absent in the blocking default.
    //
    // The Turbo Stream name is deliberately not a value here: the server derives
    // it from position + session id on both ends, so a client cannot pick which
    // stream the decision is broadcast onto.
    mode: String,
    // Absolute or relative URL of the hosted renderer script. Defaults to the
    // canonical CDN path; the view helper's script tag normally loads it first.
    scriptUrl: { type: String, default: "https://api.wavebird.ai/v1/render.js" },
  };

  connect() {
    this.#ensureRenderScript();
    this.#onTurn = this.#handleTurn.bind(this);
    this.element.addEventListener("wavebird:turn", this.#onTurn);
  }

  disconnect() {
    if (this.#onTurn) {
      this.element.removeEventListener("wavebird:turn", this.#onTurn);
      this.#onTurn = null;
    }
  }

  #onTurn = null;

  // Async delivery mode (decision #001). The DecisionPollJob broadcasts a Turbo
  // Stream that replaces the `signal` target inside this element with a data-only
  // node carrying the browser-safe payload. Stimulus fires `signalTargetConnected`
  // when that node lands; we hand the payload to the hosted renderer — the same
  // `renderPlacement`/`clearPlacement` entry points the synchronous turn uses
  // internally, so the iframe mount + viewability beacons are identical. The
  // asset_token never appears here: the server already folded it into `frame_url`.
  signalTargetConnected(el) {
    let payload;
    try {
      payload = JSON.parse(el.dataset.wavebirdPayload || "{}");
    } catch (_error) {
      payload = { fill: false };
    }

    // The signal is data, not content: consume it so repeated broadcasts cannot
    // stack up inside the slot, and so the renderer owns the element's contents
    // exactly as it does on the synchronous path.
    el.remove();

    const wavebird = typeof window !== "undefined" ? window.wavebird : null;
    if (!wavebird) return; // render.js not loaded yet; slot simply stays hidden

    if (payload && payload.fill) {
      // Handed over as `decision`, exactly as the renderer's own synchronous turn
      // does: it resolves `options.decision.placement` and then `.render`. The
      // payload is already that shape — `{ fill, placement: { render: … } }` —
      // so passing it as `placement:` would bury `render` a level too deep and
      // silently paint nothing.
      wavebird.renderPlacement({ target: this.element, decision: payload });
    } else {
      wavebird.clearPlacement({ target: this.element });
    }
  }

  // Path A. Wrap the host's work in a wavebird turn, then let it resolve.
  //
  // The event carries `detail.work` (a function returning the chat-turn promise)
  // and optionally `detail.done` — a callback invoked with the work's result (or
  // rejection) so a host that dispatched fire-and-forget can still await the
  // turn. Consuming the event (stopping default) is avoided; we only read it.
  #handleTurn(event) {
    const detail = event.detail || {};
    const work = typeof detail.work === "function" ? detail.work : () => detail.work;
    const settle = typeof detail.done === "function" ? detail.done : null;

    const promise = this.#runTurn(work);
    if (settle) {
      promise.then(
        (value) => settle(null, value),
        (error) => settle(error),
      );
    }
  }

  // Run `work` inside `window.wavebird.withTurn` when the renderer is present;
  // otherwise run it unwrapped. Never rejects for a missing renderer — the host
  // chat turn must be unaffected when wavebird is unavailable.
  async #runTurn(work) {
    const wavebird = typeof window !== "undefined" ? window.wavebird : null;
    if (!wavebird || typeof wavebird.withTurn !== "function") {
      return work();
    }

    const input = { target: this.element };
    const endpoint = this.element.dataset.wavebirdEndpoint;
    if (endpoint) input.endpoint = endpoint;

    // render.js's own default body carries only a random uuid, so the request
    // body is built here whenever the slot has anything to say: the stable
    // session id, the position hint, and — for an async slot — the delivery mode.
    const body = {};
    if (this.sessionIdValue) body.session_id = this.sessionIdValue;
    if (this.hasPositionValue) body.position = this.positionValue;
    if (this.hasModeValue) body.mode = this.modeValue;
    if (Object.keys(body).length > 0) input.body = body;

    return wavebird.withTurn(input, work);
  }

  // Load `/v1/render.js` at most once per page. render.js assigns
  // `window.wavebird`, so if it is already present another slot (or the view
  // helper's own script tag) has loaded it and there is nothing to do. A load
  // failure is swallowed: the slot simply stays hidden and the host chat flow
  // continues via the unwrapped path in `#runTurn`.
  #ensureRenderScript() {
    if (typeof document === "undefined") return;
    if (typeof window !== "undefined" && window.wavebird) return;

    const src = this.scriptUrlValue;
    if (document.querySelector(`script[src="${src}"]`)) return;

    const script = document.createElement("script");
    script.src = src;
    script.async = true;
    script.defer = true;
    script.addEventListener("error", () => {
      // Silent degrade — leave the slot hidden; the host turn still runs.
    });
    document.head.appendChild(script);
  }
}
