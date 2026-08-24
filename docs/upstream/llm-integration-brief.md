# wavebird API integration guide for LLM coding agents

Use this document as the implementation brief for adding wavebird sponsored moments to an AI app. The goal is to let the app request a sponsored placement from the backend while the model response stays untouched, then render the placement in a separate frontend slot.

## Integration goal

Add wavebird to the host app with the recommended Server API path:

1. Create or reuse a backend route that calls wavebird with a server-side secret key.
2. Add a frontend sponsored slot near the AI experience.
3. Load the hosted renderer.
4. Wrap the AI turn with `window.wavebird.withTurn()`.
5. Keep ads clearly separate from model output.
6. Hide or collapse the slot when there is no fill.

Prefer this path unless the existing app is intentionally browser-only.

## Required project values

Ask the app owner for these values or read them from existing environment configuration:

- `WAVEBIRD_SECRET_KEY`: server-only secret key. Never expose this in browser code.
- `WAVEBIRD_CLIENT_ID`: wavebird project/client id, for example `wbproj_...`.
- `NEXT_PUBLIC_WAVEBIRD_PUBLISHABLE_KEY`: publishable key, only needed for Script Tag or browser-first flows.
- Allowed origins: production and preview origins configured in the wavebird dashboard.

Recommended environment file:

```bash
WAVEBIRD_SECRET_KEY=sk_live_your_key
WAVEBIRD_CLIENT_ID=wbproj_your_client_id
WAVEBIRD_API_BASE_URL=https://api.wavebird.ai
```

## Privacy and product rules

Follow these rules in the implementation:

- Do not send prompts, full chat history, user IDs, email addresses, account data, or sensitive details to wavebird by default.
- Send only broad request context such as `job_type`, `session_id`, slot dimensions, allowed formats, timing, consent state, and broad topic category if the app owner explicitly wants it.
- Keep the model response path independent from the sponsor path.
- Do not insert sponsored text into the AI answer.
- Render sponsored moments in a separate slot controlled by the app.
- If wavebird returns no fill or an error, the AI app must continue normally.

## Recommended architecture

Backend:

- Calls `POST https://api.wavebird.ai/v1/placements?wait_ms=1500`.
- Uses `Authorization: Bearer ${WAVEBIRD_SECRET_KEY}`.
- Returns the wavebird JSON response to the browser.

Frontend:

- Loads `https://api.wavebird.ai/v1/render.js`.
- Adds a slot element with `data-wavebird-endpoint`.
- Uses `window.wavebird.withTurn("#wavebird-slot", () => sendChatMessage(message))`.
- Lets the hosted renderer mount `placement.render` and manage media, sizing, clicks, and beacons.

## Backend example: Next.js App Router

Create `app/api/wavebird/sponsor-slot/route.ts`:

```ts
import { NextResponse } from "next/server";

const API_BASE = process.env.WAVEBIRD_API_BASE_URL ?? "https://api.wavebird.ai";

type SponsorSlotRequest = {
  session_id?: string;
  job_type?: string;
  slot_hint?: {
    position?: string;
    max_width?: number;
    max_height?: number;
  };
  overrides?: Record<string, unknown>;
  consent?: Record<string, unknown>;
};

export async function POST(request: Request) {
  if (!process.env.WAVEBIRD_SECRET_KEY || !process.env.WAVEBIRD_CLIENT_ID) {
    return NextResponse.json(
      { error: "Missing WAVEBIRD_SECRET_KEY or WAVEBIRD_CLIENT_ID" },
      { status: 500 },
    );
  }

  const body = (await request.json().catch(() => ({}))) as SponsorSlotRequest;

  const wavebirdResponse = await fetch(`${API_BASE}/v1/placements?wait_ms=1500`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${process.env.WAVEBIRD_SECRET_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      client_id: process.env.WAVEBIRD_CLIENT_ID,
      session_id: body.session_id ?? `sess_${crypto.randomUUID()}`,
      job_type: body.job_type ?? "chat",
      slots_requested: 1,
      slot_hint: body.slot_hint ?? {
        position: "below",
        max_width: 728,
        max_height: 90,
      },
      overrides: body.overrides ?? {
        allowed_formats: ["banner", "clip", "native"],
        timing: "during",
      },
      consent: {
        semantic_targeting: false,
        prompt_shared: false,
        consent_source: "wavebird_consent",
        ...body.consent,
      },
    }),
  });

  const data = await wavebirdResponse.json().catch(() => null);
  return NextResponse.json(data, { status: wavebirdResponse.status });
}
```

Implementation notes:

- Replace the generated `session_id` with a stable anonymous session id if the app already has one.
- Keep `WAVEBIRD_SECRET_KEY` server-only.
- Do not pass the user's raw message into this route unless the app owner explicitly approves a stricter targeting mode.

## Backend example: Express

```ts
import express from "express";

const app = express();
app.use(express.json());

app.post("/api/wavebird/sponsor-slot", async (req, res) => {
  if (!process.env.WAVEBIRD_SECRET_KEY || !process.env.WAVEBIRD_CLIENT_ID) {
    res.status(500).json({ error: "Missing wavebird environment variables" });
    return;
  }

  const response = await fetch("https://api.wavebird.ai/v1/placements?wait_ms=1500", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${process.env.WAVEBIRD_SECRET_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      client_id: process.env.WAVEBIRD_CLIENT_ID,
      session_id: req.body.session_id ?? `sess_${crypto.randomUUID()}`,
      job_type: req.body.job_type ?? "chat",
      slots_requested: 1,
      slot_hint: req.body.slot_hint ?? {
        position: "below",
        max_width: 728,
        max_height: 90,
      },
      overrides: req.body.overrides ?? {
        allowed_formats: ["banner", "clip", "native"],
        timing: "during",
      },
      consent: {
        semantic_targeting: false,
        prompt_shared: false,
        consent_source: "wavebird_consent",
        ...req.body.consent,
      },
    }),
  });

  const data = await response.json().catch(() => null);
  res.status(response.status).json(data);
});
```

## Frontend example: plain HTML

Add this near the AI app surface:

```html
<script src="https://api.wavebird.ai/v1/render.js"></script>

<section
  id="wavebird-slot"
  data-wavebird-endpoint="/api/wavebird/sponsor-slot"
  hidden
  aria-label="Sponsored placement"
></section>

<script type="module">
  async function onUserMessage(message) {
    return window.wavebird.withTurn("#wavebird-slot", () =>
      sendChatMessage(message),
    );
  }
</script>
```

## Frontend example: React or Next.js

```tsx
import Script from "next/script";

export function AiChatSurface() {
  async function handleSend(message: string) {
    const send = () => sendChatMessage(message);

    if (typeof window !== "undefined" && window.wavebird?.withTurn) {
      return window.wavebird.withTurn("#wavebird-slot", send);
    }

    return send();
  }

  return (
    <>
      <Script src="https://api.wavebird.ai/v1/render.js" strategy="afterInteractive" />

      <section
        id="wavebird-slot"
        data-wavebird-endpoint="/api/wavebird/sponsor-slot"
        hidden
        aria-label="Sponsored placement"
      />

      {/* Existing chat UI calls handleSend(message). */}
    </>
  );
}
```

Optional TypeScript declaration:

```ts
declare global {
  interface Window {
    wavebird?: {
      withTurn<T>(slotSelector: string, work: () => Promise<T> | T): Promise<T>;
    };
  }
}
```

## Response handling contract

The Server API response has this shape:

```json
{
  "slot_id": "slot_demo_123",
  "status": "ready",
  "placement": {
    "format": "banner",
    "width": 728,
    "height": 90,
    "ad_label_text": "Sponsored",
    "render": {
      "strategy": "hosted_frame",
      "frame_url": "https://api.wavebird.ai/v1/render/wbat_asset_demo",
      "script_url": "https://api.wavebird.ai/v1/render.js",
      "media_type": "image",
      "width": 728,
      "height": 90,
      "label_text": "Sponsored",
      "sponsor_name": "Demo Sponsor",
      "click_url": "https://sponsor.example"
    }
  },
  "decision": {
    "fill": true,
    "format": "banner"
  }
}
```

If `placement` is `null`, `decision.fill` is false, or the request fails, hide the sponsored slot and keep the AI experience unchanged.

## Browser-first fallback: Script Tag

Use this only when the app owner wants a browser-first integration without a backend route:

```html
<script
  src="https://wavebird.ai/wavebird.js"
  data-client-id="wbproj_your_client_id"
  data-publishable-key="pk_publishable_your_key"
  data-job-type="chat"
  data-native-template="default">
</script>

<div
  data-wavebird-slot
  data-wavebird-position="between"
  data-wavebird-formats="banner,native">
</div>
```

Script Tag uses a publishable key and the browser origin must be allowed in the wavebird dashboard.

## SDK path

Use the SDK only when the app already has an SDK-based integration pattern or needs the package layer for compatibility. New production integrations should start with:

- Backend: `POST /v1/placements?wait_ms=1500`
- Frontend: `https://api.wavebird.ai/v1/render.js`
- Turn lifecycle: `window.wavebird.withTurn()`

## Placement choices

Start conservative:

- `position: "below"` for a slot below or between AI responses.
- `max_width: 728`, `max_height: 90` for a banner-sized first test.
- `allowed_formats: ["banner", "clip", "native"]` if the product supports all visual formats.
- `timing: "during"` when the placement should appear while the AI response is being generated.

Avoid UI patterns that make the placement look like model-generated text.

## Test checklist

After implementation, verify:

- The AI response still appears when wavebird is unavailable.
- The secret key is never present in browser bundles, HTML, logs, or network calls from the browser.
- The backend route returns a JSON response from `/v1/placements`.
- `render.js` loads without CSP errors.
- The sponsored slot is hidden on no-fill.
- A filled placement renders in a separate slot, not inside the answer text.
- The placement label remains visible.
- Mobile layout does not overflow.
- The app owner can disable the slot or categories without code changes.

## LLM implementation checklist

When applying this document to a codebase:

1. Detect the framework and routing layer.
2. Add the server route using the app's existing API style.
3. Add the environment variables to the app's env schema or deployment docs.
4. Add the frontend slot near the AI response surface.
5. Load `render.js` once.
6. Wrap the existing send/generate function with `window.wavebird.withTurn()`.
7. Preserve all existing chat behavior on error or no-fill.
8. Add a small integration test or smoke test if the repo has a matching test setup.
9. Do not refactor unrelated AI, auth, billing, or ad-format code.
