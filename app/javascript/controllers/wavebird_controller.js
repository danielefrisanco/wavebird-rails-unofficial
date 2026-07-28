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
  static values = {
    sessionId: String,
    position: String,
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
    if (this.sessionIdValue) input.body = { session_id: this.sessionIdValue };

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
