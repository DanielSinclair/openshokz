# OpenShokz

macOS widget-style app that downloads YouTube videos and podcasts as audio, copies them to Shokz swimming/MP3 headphones (OpenSwim / OpenSwim Pro and similar), and lets you browse what’s on the device.

## Install

- **Homebrew:** `brew install --cask danielsinclair/tap/openshokz`
- **Direct download:** [latest DMG](https://github.com/DanielSinclair/openshokz/releases/latest) (Apple silicon) — drag OpenShokz into Applications
- **Mac App Store:** coming soon

## Usage

1. Plug in your Shokz — wait for the disk to mount (e.g. **OpenSwim**, **SWIM PRO**).
2. Tap **+**, paste a YouTube or podcast URL, send to the device.
3. Unplug when done — the app quits after a short settle delay.

Audio lands as **MP3** with embedded title and cover art.

## Architecture

SwiftUI + SwiftData with strict concurrency. The moving parts:

| Piece | Role |
|-------|------|
| `DiskArbitrationMonitor` / `ShokzVolumeMonitor` | Event-driven device detection — mount, unmount, and cable yanks arrive as callbacks, no polling |
| `DeviceIOCoordinator` | Actor that serializes every USB volume operation and health-gates a wedged disk |
| `ShokzFileEnumerator` | POSIX directory listing with per-directory timeouts, breadth-first with early batches |
| `LibraryViewModel` | Persistent library cache — paints instantly on connect, reconciles against one background listing |
| `DownloadService` / `MediaPipeline` | Native download pipeline (YouTubeKit extraction, podcast episode resolution, direct media links) transcoded to mp3 via bundled ffmpeg; track metadata is captured at download time |
| `TransferService` | Copies audio onto the device with hard timeouts, serialized on the device-I/O lane |
| Sparkle | Auto-updates from the site’s [`appcast.xml`](site/appcast.xml) |

The app is fully sandboxed: Shokz volume access flows through a one-time
per-device grant persisted as a security-scoped bookmark
(`VolumeAccessManager`), all volume I/O is plain POSIX/FileManager (no Finder
automation), and the bundled helpers run inside the app's sandbox. USB
enumeration always runs off the main thread so a wedged disk can never freeze
the UI.

## Development

- macOS 15+, Xcode 16+ (or Xcode 26 for Liquid Glass)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

```bash
./scripts/fetch-binaries.sh   # bundled helpers into the app resources
xcodegen generate
open OpenShokz.xcodeproj
```

Or build from the CLI (DerivedData outside iCloud/Documents — FileProvider xattrs break codesign):

```bash
xcodebuild -scheme OpenShokz -configuration Debug -derivedDataPath /tmp/OpenShokz-DerivedData build
open /tmp/OpenShokz-DerivedData/Build/Products/Debug/OpenShokz.app
```

### Cursor / VS Code

| Action | How |
|--------|-----|
| **Build** (Debug) | `⌘⇧B` or Run Task → **Build** |
| **Build and Run** | `F5` (config **Build and Run**) or Run Task → **Build and Run** |
| **Build Release** | Run Task → **Build Release** |
| **Build and Run Release** | Run and Debug → **Build and Run Release**, or Run Task → **Build and Run Release** |

### Tests

Lint, unit, and UI tests run in [PR Checks](.github/workflows/pr-checks.yml)
on every push and pull request. Locally:

```bash
xcodegen generate
xcodebuild \
  -scheme OpenShokz \
  -configuration Debug \
  -derivedDataPath /tmp/OpenShokz-DerivedData \
  -destination "platform=macOS" \
  test \
  -only-testing:OpenShokzTests
```

UI tests (`-only-testing:OpenShokzUITests`) need the ad-hoc signing flags from
the workflow but no USB or network. Optional real-device check:
`OPENSHOKZ_UITEST_USB=1` with a Shokz disk mounted.
