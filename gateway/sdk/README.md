# `@rockorager/waymote`

Framework-free browser client for a Waymote gateway. The SDK owns
WebSocket recovery, WebCodecs video and audio, input and IME forwarding,
clipboard transport, presentation timing, and optional remote-output sizing.
The application owns the canvas, controls, status UI, styling, and browser
permission prompts.

```ts
import { WaymoteSession } from "@rockorager/waymote";

const canvas = document.querySelector<HTMLCanvasElement>("#display")!;
const session = new WaymoteSession({
  endpoint: "https://desktop.example.com",
  remoteDisplay: { mode: "manual" },
});
const surface = session.attachSurface({ canvas });

session.on("state", (state) => renderState(state));
session.on("stats", (stats) => renderStats(stats));
session.connect();
```

Applications that authenticate WebSockets can supply a synchronous or
asynchronous socket factory. It is invoked separately for every initial
connection and reconnect, so credentials can always be refreshed:

```ts
const session = new WaymoteSession({
  audio: false,
  createWebSocket: async (_path, url) => {
    const token = await getFreshDesktopToken();
    return new WebSocket(url, [token]);
  },
});
```

Keep credentials in the WebSocket protocol or another authorization mechanism;
do not place them in query parameters. Setting `audio: false` prevents the SDK
from opening `/audio` and makes `session.audio.enable()` a no-op.

Use `session.disconnect()` for a temporary, reconnectable pause. When an
application permanently removes a session, release all transport, decoder,
audio, surface, and event resources with:

```ts
await session.dispose();
```

Disposal is idempotent and terminal. It also disposes the attached surface;
subsequent attempts to reconnect, attach another surface, subscribe, or invoke
a controller throw an error. `surface.dispose()` remains available when an
application only needs to detach or replace the current canvas.

During local development, install the package directly from the repository:

```sh
npm install ./gateway/sdk
```

A running gateway also serves the same ESM implementation at `/waymote.js` and
its declarations at `/waymote.d.ts`.

Remote resizing is manual by default. Choose a fixed remote size with
`session.remoteDisplay.fixed({ width, height, scale })`, or explicitly opt into
viewport-driven sizing with `session.remoteDisplay.observe({ element })`.
Changing the canvas's CSS or backing dimensions never implicitly resizes the
remote compositor.

Printable keyboard input follows the layout resolved by the browser, so users
do not need to select their local keyboard layout in the application. Ctrl,
Meta, and ordinary Alt shortcuts remain physical-key shortcuts. The gateway's
`-xkb-layout` setting remains the fallback for older browser clients.

Audio must be enabled from a user gesture with `session.audio.enable()`. The
package includes its AudioWorklet beside the SDK module; `audioWorkletURL` can
override that URL when an application's bundler or content policy requires a
separate asset location.

The browser needs WebCodecs H.264 and Opus support. Clipboard and audio APIs
also require a secure context and their normal browser permissions.
