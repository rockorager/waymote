# Repository guidance

Keep the root README product-focused. Contributor setup, validation, demo, and
release procedures belong in this file rather than in the product overview.

## Toolchain and setup

- Zig 0.16.0 and Go 1.26.5 are the supported toolchains.
- Native builds require Wayland client and xkbcommon development packages.
- FFmpeg with `libopus` is required at runtime for session audio, not at
  compile time.
- In an Amp orb, `.agents/setup` provisions the toolchains, Labwc, PulseAudio,
  ioquake3, the Quake III demo data, and supporting Wayland utilities.

## Build and validation

Run the complete native and gateway test suite from the repository root:

```sh
zig build test -Doptimize=ReleaseSafe
```

Build the installed binaries with:

```sh
zig build install -Doptimize=ReleaseSafe
```

This produces `zig-out/bin/waymote-streamd` and
`zig-out/bin/waymote-gateway`. For SDK changes, also run:

```sh
node --check gateway/sdk/waymote.js
node --check gateway/sdk/audio-player.js
node --input-type=module --check < gateway/examples/web/client.js
node --test gateway/sdk/waymote.test.mjs
npx --yes --package typescript@5.7.3 tsc \
  --noEmit --skipLibCheck false --lib ES2022,DOM gateway/sdk/waymote.d.ts
npm pack --dry-run ./gateway/sdk
```

For changes under `h264/`, also check the encoder bit for bit against FFmpeg's
H.264 decoder (needs `ffmpeg` on `PATH`; not run in CI):

```sh
zig build h264-check -Doptimize=ReleaseSafe
```

Use the narrowest relevant subset while iterating, then run the complete checks
before publishing a release.

## Amp demo

Start or refresh the supervised Labwc, PulseAudio, and Quake III demo with:

```sh
amp orb services ensure
```

The service is declared in `.amp/services.yaml` and launched by
`scripts/run-labwc-demo`. It uses a fixed 1280x720, 30 Hz virtual output. Do not
replace the supervised service with a background shell process.

## Manual session

After building, start a compatible compositor and export its `WAYLAND_DISPLAY`.
Launch the gateway from the repository root with:

```sh
zig-out/bin/waymote-gateway \
  -streamd zig-out/bin/waymote-streamd \
  -listen 127.0.0.1:8080 \
  -frame-rate 30 \
  -bitrate 12000 \
  -xkb-layout us
```

Pass a Pulse-compatible monitor source with `-audio-source` to enable session
audio. Use matching nonzero `-fixed-width` and `-fixed-height` values when
viewers must not reconfigure the compositor output.

## Release procedure

The Git tag is the release version source of truth. The workflow injects the
tag version into the Zig daemon, Go gateway, and staged npm package. The source
package remains at its development version between releases.

Before the first npm publication, add a granular npm token with publish access
for `@rockorager/waymote` as the `NPM_TOKEN` GitHub Actions secret.

Build release artifacts locally without publishing:

```sh
scripts/package-release 0.1.0-alpha.1
```

The script writes the combined Linux server archive, standalone browser SDK
archive, npm tarball, staged npm directory, and `SHA256SUMS` under
`zig-out/release/`. Confirm both binaries report the requested version before
tagging.

Publish by pushing an annotated semantic-version tag:

```sh
git tag -a v0.1.0-alpha.1 -m "Waymote 0.1.0 alpha 1"
git push github v0.1.0-alpha.1
```

Prerelease versions publish to the npm `next` tag and create a GitHub
prerelease. Versions without a prerelease suffix publish to npm `latest` and
create a full GitHub release. Do not manually publish only one channel; the
GitHub workflow keeps the native, GitHub SDK, and npm artifacts synchronized.
