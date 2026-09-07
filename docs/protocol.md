# Waymote wire protocol

Waymote currently uses wire protocol version 2. All integers are little-endian.

## Browser input

Browser input records are 16 bytes:

```text
version:u8=2, type:u8, state:u8, reserved:u8,
a:u32, b:u32, sequence:u32
```

Types 1–5 are absolute motion, button, scroll, key, and release-all. Type 8 is
relative motion, where `a` and `b` contain finite bounded `f32` bits. Resize
(type 6) uses width and height in `a` and `b`, with scale in the low 16 bits and
request ID in the high 16 bits of the final word. Quality (type 9) carries kbps,
FPS, and encoded scale percent. Text (type 10) is followed by at most 4000
UTF-8 bytes without NUL; state 1 is preedit and state 0 is commit, payload
length is `a`, and input sequence is `b`.

Key records use the Linux evdev keycode in `a`. On a press, `b` may contain the
browser-resolved XKB keysym for one printable character. Latin-1 characters use
their standard keysym value; other Unicode scalar values use `0x01000000 | codepoint`.
A zero `b` keeps physical-key behavior. Repeat and release records retain the
route selected by the initial press, using `a` as the held-key identity. The
gateway advertises resolved keysym support in control-state messages; clients
must send zero when that capability is absent.

## Stream daemon events

Daemon stdout events have an 8-byte header:

```text
version:u8=2, type:u8, reserved:u16, payload_length:u32
```

Type 1 is clipboard. Type 2 has a fixed 32-byte frame metadata payload:
generation `u32`, encoded width and height `u16`, capture `CLOCK_MONOTONIC`
nanoseconds `u64`, media sequence `u64`, latest input sequence `u32`, and
encoder FPS `u32`. Type 3 is the 20-byte resize-applied event: request ID
`u16`, padding, width and height `u32`, scale `u16`, padding, and generation
`u32`.

## Browser video

Browser video messages use a 40-byte header: version, type, flags, and reserved
(4 bytes); media sequence (8); media timestamp in microseconds (8); generation
(4); encoded width and height (2 each); capture monotonic nanoseconds (8); and
latest applied input sequence (4). One Annex-B access unit follows the header.

Capture and browser clocks are not assumed comparable. Low-RTT ping/pong
samples estimate the offset between server `CLOCK_MONOTONIC` and browser
`performance.now()`.

## Browser audio

Browser audio messages use a 24-byte header: version, type, flags, and reserved
(4 bytes); extended RTP sequence (8); estimated monotonic capture timestamp in
microseconds (8); and stream generation (4). One raw Opus packet follows.

The gateway maps the extended 48 kHz RTP clock onto its monotonic clock using a
filtered lower envelope of packet arrival times. The discontinuity flag is set
after packet loss, encoder restarts, and per-client queue overflow.

Once clock confidence is established, the browser schedules decoded video and
audio to the selected 60, 100, or 180 ms capture-to-presentation target. Video
uses a bounded decoded-frame queue; audio is placed at matching AudioContext
frames by the AudioWorklet. Until clock or AudioContext output timing is usable,
audio retains a bounded 60 ms queue fallback and does not allow latency to grow
beyond 200 ms.
