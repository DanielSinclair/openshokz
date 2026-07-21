# AGENTS.md

## Cursor Cloud specific instructions

This repository has two parts with very different platform requirements:

- **`OpenShokz` macOS app** (SwiftUI + SwiftData, `OpenShokz.xcodeproj` generated
  from `project.yml` via XcodeGen). This is the primary product. It is
  **macOS-only** (Xcode 16+, macOS 15+, AppKit/SwiftUI/SwiftData/DiskArbitration,
  Sparkle) and **cannot be built, run, linted, or tested on the Linux Cursor
  Cloud VM** — there is no Swift toolchain, no `xcodebuild`/`xcodegen`, and its
  frameworks do not exist on Linux. Build/lint/test commands for it live in
  `README.md` (`## Development`, `## Tests`) and run in CI on `macos-15`
  (`.github/workflows/pr-checks.yml`). Do not attempt to set this up on Linux.

- **`site/` landing site** — a static HTML/CSS/JS site (GitHub Pages). This is
  the only runnable component on the Linux VM. There is **no build step and no
  dependencies to install** (no `package.json`).

### Running the site (Linux VM)

Serve it with the preinstalled `python3` (see `site/README.md`):

```sh
python3 -m http.server 8377 --directory site
```

Then open `http://localhost:8377/`.

Notes:
- The "Liquid glass" hero effect needs WebGPU. Headless/no-GPU browsers log
  `Liquid glass unavailable: No WebGPU adapter` and fall back to the CSS
  `backdrop-filter` glass — this warning is **expected**, not a bug.
- The hero "app window" is an animated HTML/CSS recreation driven by `demo.js`
  (loops through paste → download → copy, plus a context-menu delete). Podcast
  titles/durations/thumbnails under `site/assets/thumbs/` are baked in.
- Editing files under `site/` is picked up on browser refresh (static server,
  no hot reload).
