// Local stand-in for wavebird's hosted https://api.wavebird.ai/v1/render.js.
//
// The suite runs with net connections disabled, so the real hosted script cannot
// be fetched. This file implements the *contract* the real one exposes, verified
// against docs/upstream/render-js-snapshot-2026-07-18.js:
//
//   window.wavebird.withTurn(input, work)   -> startTurn + work + turn.finish()
//   window.wavebird.startTurn(input)        -> {decision, finish, cancel}; POSTs
//                                              to data-wavebird-endpoint, then
//                                              renders or clears
//   window.wavebird.renderPlacement(opts)   -> mounts the hosted iframe, reveals
//   window.wavebird.clearPlacement(opts)    -> empties + hides the slot
//
// Deliberately simplified vs. the real script: no beacons, no IntersectionObserver,
// no viewability timing. Those are the renderer's own concern and are not part of
// the surface this gem drives. What matters here is the element lifecycle the gem
// depends on: who POSTs, who reveals, who hides.
//
// Kept honest by spec/wavebird/system/render_js_contract_spec.rb, which asserts
// the real snapshot still exposes exactly the entry points stubbed here.
(function (global) {
  "use strict";

  function byTarget(t) {
    return typeof t === "string" ? global.document.querySelector(t) : t;
  }

  function readTurnOptions(input) {
    var isOptions =
      input &&
      typeof input === "object" &&
      !input.nodeType &&
      ("target" in input || "endpoint" in input || "body" in input);
    var target = byTarget(isOptions ? input.target : input);
    return {
      target: target,
      endpoint:
        (isOptions && input.endpoint) ||
        (target && target.getAttribute("data-wavebird-endpoint")) ||
        "/api/sponsor-slot",
      body: isOptions && "body" in input ? input.body : { session_id: "generated" },
    };
  }

  // Ported verbatim in behaviour from the snapshot's placementFrom/renderFrom:
  // an endpoint response is unwrapped to a placement, and a placement resolves
  // to a render *only* via `p.render.frame_url` or by rebuilding the URL from
  // `p.asset_token`. Anything else resolves to null and paints nothing.
  //
  // This is the part that must not be written to suit the gem's payload — that
  // is precisely how a shape mismatch with the real renderer slipped past a
  // green suite once already.
  // The real script derives this from its own <script src>; the stand-in is
  // served from the same origin as the app under test, so the document origin is
  // equivalent here.
  function scriptOrigin() {
    return global.location.origin;
  }

  function placementFrom(input) {
    if (!input) return null;
    if (input.placement) return input.placement;
    if (input.decision && input.decision.placement) return input.decision.placement;
    return input;
  }

  function renderFrom(p) {
    var r = p && p.render;
    if (r && r.frame_url) return r;
    var token = p && p.asset_token;
    if (!token) return null;
    var w = p.width || 300;
    var h = p.height || 250;
    return {
      strategy: "hosted_frame",
      frame_url: scriptOrigin() + "/v1/render/" + encodeURIComponent(token),
      script_url: scriptOrigin() + "/v1/render.js",
      width: w,
      height: h,
      aspect_ratio: w + "/" + h,
      label_text: p.ad_label_text || "Sponsored",
      sponsor_name: p.sponsor_name || null,
    };
  }

  var api = global.wavebird || {};

  // Test affordances: let specs observe what the renderer was asked to do.
  api.__calls = { render: [], clear: [], turns: [] };

  api.clearPlacement = function (options) {
    var target = byTarget((options && options.target) || options);
    if (!target) return;
    target.replaceChildren();
    target.hidden = true;
    target.removeAttribute("data-wavebird-status");
    api.__calls.clear.push(true);
  };

  api.renderPlacement = function (options) {
    var target = byTarget(options && options.target);
    // Resolved from the options object itself, like the real renderer: it accepts
    // `{placement: …}` or `{decision: …}` and unwraps either the same way.
    var render = renderFrom(placementFrom(options));
    if (!target || !render || !render.frame_url) {
      api.clearPlacement({ target: target });
      return Promise.resolve(null);
    }

    var iframe = global.document.createElement("iframe");
    iframe.src = render.frame_url;
    iframe.title = "Sponsored content";
    iframe.setAttribute("data-wavebird-frame", "1");
    iframe.sandbox = "allow-scripts";
    iframe.style.cssText = "width:100%;height:100%;border:0;";

    target.replaceChildren(iframe);
    target.hidden = false;
    target.setAttribute("data-wavebird-status", "rendered");
    api.__calls.render.push(render.frame_url);
    return Promise.resolve(render);
  };

  api.startTurn = function (input) {
    var opts = readTurnOptions(input);
    var target = opts.target;
    api.__calls.turns.push(opts.endpoint);

    if (!target) {
      return {
        target: null,
        decision: Promise.resolve(null),
        finish: function () { return Promise.resolve(); },
        cancel: function () {},
      };
    }

    // A new turn always starts from a cleared slot, like the real renderer.
    api.clearPlacement({ target: target });

    var turn = { target: target, finished: false };
    turn.decision = global
      .fetch(opts.endpoint, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(opts.body === undefined ? {} : opts.body),
      })
      .then(function (response) {
        if (!response.ok) throw new Error("wavebird decision failed: " + response.status);
        return response.json();
      })
      .then(function (decision) {
        // Async mode answers { pending: true } and reveals later over a Turbo
        // Stream; nothing to render inline.
        if (!decision || decision.pending) return decision;
        // The real startTurn resolves the endpoint's answer by wrapping it as
        // `{decision: response}` — so the response must carry `placement`.
        var p = placementFrom({ decision: decision });
        if (!p || !p.render) {
          api.clearPlacement({ target: target });
          return decision;
        }
        return api
          .renderPlacement({ target: target, decision: decision })
          .then(function () { return decision; });
      })
      .catch(function () {
        api.clearPlacement({ target: target });
        return null;
      });

    turn.finish = function () { return turn.decision.then(function () {}); };
    turn.cancel = function () {};
    return turn;
  };

  api.withTurn = async function (input, work) {
    var turn = api.startTurn(input);
    try {
      return await (typeof work === "function" ? work(turn) : work);
    } finally {
      await turn.finish();
    }
  };

  global.wavebird = api;
})(window);
