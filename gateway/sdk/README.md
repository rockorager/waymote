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

A server that captures one of several host displays can let viewers choose
among them. The Waymote gateway does not; `session.displays.state` stays `null`
and `session.displays.select(id)` returns `false` unless the server sends a
`display-state` message on the control socket:

```json
{ "type": "display-state", "displays": [{ "id": "1", "name": "Built-in",
  "width": 3024, "height": 1964, "isMain": true }], "selectedID": "1",
  "generation": 3, "switching": false }
```

`generation` is the video generation that shows the selected display, and an
optional `error` string reports a failed switch. Selecting a display sends
`{ "type": "display-select", "id": "2" }` once the viewer holds input control.
Input, text, and clipboard writes are suppressed from the selection until a
frame of the reported generation is drawn; the SDK then sends
`{ "type": "display-presented", "generation": 4 }` and resumes input. The
`displays` event reports each change, including `null` when the control
connection closes.

Printable keyboard input follows the layout resolved by the browser, so users
do not need to select their local keyboard layout in the application. Ctrl,
Meta, and ordinary Alt shortcuts remain physical-key shortcuts except for paste.
The gateway's `-xkb-layout` setting remains the fallback for older browser clients.

`session.input.setSwapCommandControl(true)` swaps Command (Super) and Control
for hardware keys, so a Mac user's Command-C reaches a Linux desktop as Ctrl-C.
The platform paste gesture keeps working either way.

Touch devices have no Ctrl, Alt, Esc, or arrow keys, so applications can draw
their own key strip. `session.input.tapKey(key, modifiers)` taps one Linux key
code with the given modifiers held. `session.input.setStickyModifiers(keys)`
latches one-shot modifiers, reported in `state.input.stickyModifiers`, for the
next non-modifier key, whether it comes from `tapKey`, a hardware key, or a
character typed on the on-screen keyboard, which is then sent as a shortcut key
(Ctrl and "c" become Ctrl-C). `session.input.pasteText(text)` writes text to
the remote clipboard and taps the remote paste shortcut.

```ts
session.input.setStickyModifiers([29]); // Ctrl for the next key
session.input.tapKey(15); // Ctrl-Tab
session.input.tapKey(1); // Esc
```

The browser's native paste shortcut (Command-V on Apple platforms, Ctrl-V
elsewhere) sends local clipboard text and pastes remotely with Ctrl-V; adding
Shift uses Ctrl-Shift-V. Ctrl-V on macOS passes through to the remote application
without reading the local clipboard. Native paste does not request clipboard-read
permission.

When the remote desktop runs macOS, pass `remotePlatform: "macos"` so the paste
gesture taps Command-V (Command-Shift-V with Shift) on the remote instead. The
default, `"linux"`, uses Ctrl-V.

With `clipboardAutoSync: true` in `attachSurface`, new remote copies are
written to the host clipboard while the page has focus. The gateway replays its
latest clipboard whenever it grants control; that replay updates
`session.clipboard.latestRemoteText` and the `clipboard` event but is not
written, so focusing the desktop to paste never replaces a fresh host copy.

Audio must be enabled from a user gesture with `session.audio.enable()`. The
package includes its AudioWorklet beside the SDK module; `audioWorkletURL` can
override that URL when an application's bundler or content policy requires a
separate asset location.

The browser needs WebCodecs H.264 and Opus support. Clipboard and audio APIs
also require a secure context and their normal browser permissions.
