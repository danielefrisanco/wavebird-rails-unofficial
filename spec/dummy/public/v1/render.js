// Local stand-in for wavebird's hosted https://api.wavebird.ai/v1/render.js.
//
// The suite runs with net connections disabled, so the real hosted script cannot
// be fetched. This file implements the *contract* the real one exposes, verified
// against docs/upstream/render-js-snapshot-2026-08-23.js:
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
// Kept honest by spec/wavebird/render_js_contract_spec.rb, which asserts the
// real snapshot still exposes the entry points stubbed here AND that every gate
// the snapshot enforces is enforced here too. That second half exists because
// this file being frozen at an old contract is exactly how the gem shipped a
// browser integration that could not run: wavebird added the consent gate on
// 2026-08-23, this stand-in did not have it, and 27 green system examples said
// nothing (plan v3).
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
      ("target" in input ||
        "endpoint" in input ||
        "body" in input ||
        "authoritative_consent" in input);
    var target = byTarget(isOptions ? input.target : input);
    return {
      target: target,
      authoritative_consent: isOptions ? input.authoritative_consent : null,
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

  // Ported from consentAllowsAdActivity in the 2026-08-23 snapshot, rule for
  // rule. Every one of these is a way the real renderer silently declines to run
  // a turn, so a stand-in that skipped any of them would let the system suite
  // pass on a payload the real script refuses.
  function resolveAuthoritativeConsent(resolver) {
    try {
      return typeof resolver === "function" ? resolver() : resolver;
    } catch (_) {
      return null;
    }
  }

  function consentAllowsAdActivity(resolver) {
    var consent = resolveAuthoritativeConsent(resolver);
    if (!consent || typeof consent !== "object" || consent.lifecycle_state !== "granted") return false;
    if (!Number.isSafeInteger(consent.revision) || consent.revision < 1) return false;
    if (!Number.isSafeInteger(consent.updated_at_ms) || !Number.isSafeInteger(consent.expires_at_ms)) return false;
    return consent.expires_at_ms > Date.now();
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

  // Gate 3 of 3. Note the fallback to the *placement's* own consent: that is
  // what lets the gem's async reveal satisfy the gate with no JavaScript at all,
  // by carrying consent in the broadcast payload (SlotPayload#with_consent).
  api.renderPlacement = function (options) {
    var target = byTarget(options && options.target);
    // Resolved from the options object itself, like the real renderer: it accepts
    // `{placement: …}` or `{decision: …}` and unwraps either the same way.
    var placement = placementFrom(options);
    var render = renderFrom(placement);
    var consent =
      (options && options.authoritative_consent) ||
      (placement && placement.authoritative_consent);
    if (!target || !render || !render.frame_url || !consentAllowsAdActivity(consent)) {
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

    // Gate 1 of 3, before the fetch: no consent, no request. This is the one
    // that made the real integration inert -- the endpoint is never called and
    // nothing is logged.
    if (!consentAllowsAdActivity(opts.authoritative_consent)) {
      return {
        target: target,
        decision: Promise.resolve(null),
        finish: function () { return Promise.resolve(); },
        cancel: function () {},
      };
    }

    var turn = { target: target, finished: false, authoritativeConsent: opts.authoritative_consent };
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
        // Gate 2 of 3: consent can be withdrawn while the request is in flight.
        if (!consentAllowsAdActivity(turn.authoritativeConsent)) {
          api.clearPlacement({ target: target });
          return null;
        }
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
