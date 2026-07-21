# OpenShokz landing site

Static site — no build step. `index.html` lives at the top of this directory.

Local preview:

```sh
python3 -m http.server 8377 --directory site
```

Deploys to GitHub Pages via `.github/workflows/pages.yml` on pushes that touch
`site/`. The canonical URL everywhere (SEO tags, sitemap, Sparkle feed,
cask homepage) is `https://danielsinclair.github.io/openshokz` — update those
if a custom domain comes back.

## Glass

Liquid glass is rendered with [`@liquid-dom/core`](https://github.com/AndrewPrifer/liquid-dom)
(vendored in `vendor/liquid-dom/`, WebGPU). The page background is painted on a
2D canvas and uploaded as the glass core's `backdropTexture`, so no experimental
HTML-in-Canvas flag is needed. Browsers without WebGPU fall back to the CSS
`backdrop-filter` glass in `styles.css` — same look, no refraction.

## Interactive card

The app window in the hero is a native HTML/CSS recreation (true glass via
backdrop-filter, so it survives the 3D hover parallax), not a screenshot.
`demo.js` scripts a cursor that adds a video (paste → download → copy to
headphones) and deletes one via the row context menu, on a loop. Podcast
titles, durations, and thumbnails are real (fetched at build time).

## Assets

- `assets/thumbs/*.jpg` — real YouTube thumbnails for the demo library.
- `assets/icon-light.png` — light-mode icon composed from the Icon Composer
  glyph (`OpenShokz.icon/Assets/foreground.svg`).
- `assets/mac-app-store-badge.svg` — official Apple badge
  (tools.applemediaservices.com).
- `assets/hero.png` — real app window capture (used as the og:image).

## Easter egg

After 30 seconds, a pixel Codex-pet swims lengths of a lane on the right —
front crawl down, tumble-turn, backstroke up (`pet.js`). `?pet` triggers it
immediately; `?pety=<y>` starts it mid-lane (handy for screenshots).

## TODO

- Replace the Mac App Store placeholder link in `index.html` with the real
  app id once published.
