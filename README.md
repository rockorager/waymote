# Waymote

Waymote turns a wlroots Wayland session into an interactive browser experience.
It streams low-latency video and audio, forwards pointer and keyboard input,
synchronizes text clipboard data, and can resize the remote output—all through
a framework-independent TypeScript client.

Waymote is designed for products that need to embed a remote Linux workspace,
game, kiosk, or development environment without coupling their frontend to a
particular UI framework.

## What it provides

- H.264 video and Opus audio delivered to browser WebCodecs
- Absolute and pointer-lock relative mouse input
- Browser-layout-aware keyboard, composition, and Wayland input-method forwarding
- Bidirectional text clipboard synchronization
- Fixed, manual, or viewport-driven remote output sizing
- Capture-to-presentation timing, latency targets, and stream statistics
- Automatic reconnect, decoder recovery, and bounded low-latency queues
- A typed ESM client that works with React, Vue, Svelte, or the plain DOM

Only one viewer owns input and clipboard control at a time. Additional viewers
can continue watching the same session without reconfiguring its output.

## Browser SDK

The browser package is `@rockorager/waymote`:

```ts
import { WaymoteSession } from "@rockorager/waymote";

const canvas = document.querySelector<HTMLCanvasElement>("#display")!;
const session = new WaymoteSession({
  endpoint: "https://desktop.example.com",
  remoteDisplay: {
    mode: "fixed",
    width: 1280,
    height: 720,
    scale: 1,
  },
});

const surface = session.attachSurface({
  canvas,
  controlOnFocus: true,
  clipboardAutoSync: true,
});

session.on("state", (state) => renderConnectionState(state));
session.on("stats", (stats) => renderPerformanceMetrics(stats));
session.on("error", (error) => reportError(error));
session.connect();

// Browser policy requires these calls to originate from a user gesture.
await session.audio.enable();
await surface.requestPointerLock();
```

The SDK owns transport recovery, media decoding, presentation timing, input,
clipboard transport, and output-size requests. The consuming application owns
the canvas, controls, status UI, styling, and browser permission prompts.

State snapshots are immutable. `state`, `stats`, `clipboard`, `resize`,
`quality`, and `error` events let an application render the experience without
the SDK making assumptions about its framework or design system.

### Remote display policies

Remote sizing is manual by default. Changing a canvas's CSS or backing size
does not implicitly resize the Wayland compositor.

- `manual` leaves output management entirely to the application.
- `fixed` requests one stable width, height, and Wayland scale.
- `observe` follows an element using bounded, debounced resize requests.

Local CSS scaling always remains independent from the remote output mode. A
fixed mode is recommended when several viewers share one encoder.

The complete API reference and browser requirements are documented in
[`gateway/sdk/README.md`](gateway/sdk/README.md). A framework-free example UI
lives in [`gateway/examples/web`](gateway/examples/web).

## Server

The server distribution contains two processes:

- `waymote-streamd` is a privileged Wayland client responsible for capture,
  virtual input, clipboard access, output management, and FFmpeg supervision.
- `waymote-gateway` owns the browser-facing HTTP and WebSocket endpoints. It
  embeds the SDK and example frontend and launches the stream daemon.

The gateway is the only process intended to face the network:

```text
wlroots compositor
  -> Wayland shared-memory capture
  -> waymote-streamd
  -> H.264 and Opus RTP over loopback
  -> waymote-gateway
  -> browser WebSockets and WebCodecs

browser input and clipboard
  -> waymote-gateway
  -> validated daemon messages
  -> Wayland virtual input and data-control protocols
```

The server requires FFmpeg with `libx264`, a Pulse-compatible audio source for
audio, and the relevant Wayland protocols. The release archive currently
targets Linux x86-64.

## Compositor compatibility

Labwc is the compositor tested by this repository. Other wlroots compositors
should work when they expose the required protocols:

- `zwlr_screencopy_manager_v1` for capture
- `zwlr_virtual_pointer_manager_v1` for pointer input
- `zwp_virtual_keyboard_manager_v1` for keyboard input
- `zwlr_output_manager_v1` for optional output resizing
- `ext_data_control_manager_v1` for clipboard synchronization
- `zwp_input_method_manager_v2` for browser text composition

Capture and input remain usable at the compositor's existing output size when
output management is unavailable. Creating the initial output remains the
responsibility of the compositor or session launcher.

## Browser compatibility

The browser must provide WebCodecs support for H.264 and Opus. Audio,
clipboard, and pointer lock remain subject to normal browser user-gesture,
secure-context, and permission requirements.

The current implementation has been exercised primarily in Chromium on Linux.

## Security

Waymote does not currently authenticate remote sessions. A production
deployment must terminate TLS and enforce authentication in a trusted ingress
or reverse proxy. Exposing the gateway without that boundary exposes input and
clipboard control of the Wayland session.

Use the gateway's public-origin restriction to reject WebSocket connections
from unexpected browser origins.

## Current status

Waymote is an early release and currently has these constraints:

- Clipboard synchronization is text-only and capped at 1 MiB.
- The software encoder uses FFmpeg `libx264`; hardware encoding is not yet
  integrated.
- Session audio requires a Pulse-compatible monitor source but fails
  independently from video and input.
- Slow viewers drop stale encoded frames and resume at the next keyframe rather
  than accumulating latency.
- Linux x86-64 is the first packaged server target.

The binary protocol is documented separately in
[`docs/protocol.md`](docs/protocol.md).

Waymote is available under the [MIT License](LICENSE).
