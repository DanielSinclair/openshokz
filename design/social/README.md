# Social / launch assets

Rendered at 2× via headless Chrome, normalized to 1200×630. Sources are the
`*.html` files (edit + re-render with Chrome `--screenshot`).

## Images (1200×630, `summary_large_image`)

- `og-a.png` — light, icon left / copy right. Clean and literal. *(closest to
  the current deployed `assets/og.png`.)*
- `og-b.png` — light, centered, gradient "YouTube & podcasts". Reads best as a
  standalone card. **Recommended for the launch tweet.**
- `og-c.png` — dark pool-blue with faint lane lines, "for the pool". Playful,
  on-theme.

## Video

- `og-motion.mp4` — 6s, 1200×630, H.264/yuv420p, fade + gentle push-in on the
  centered card. Drop straight into a tweet.

To make `og-b` the site's share image, copy it over `site/assets/og.png`
(the meta tags already point there).

## Tweet copy options

**1 — Punchy launch**
> OpenShokz 🏊 — a free, open-source Mac app that downloads YouTube videos and
> podcasts straight onto your Shokz swim headphones.
> No more fighting the file transfer. Paste a link, hit send.
> github.com/DanielSinclair/openshokz

**2 — Problem → solution**
> Getting podcasts onto Shokz OpenSwim headphones has always been fiddly.
> So I built OpenShokz: paste a YouTube or podcast link → it downloads,
> converts to MP3, and copies to the drive. Native, sandboxed, free & open
> source. macOS.

**3 — Feature-led**
> OpenShokz 1.0 🏊
> • Paste a YouTube or podcast episode link
> • Downloads + converts to MP3 on your Mac
> • Copies straight to your OpenSwim / OpenSwim Pro
> • Tells you exactly when it's safe to unplug
> Free & open source →

**4 — Short & casual**
> Made a little Mac app: load YouTube & podcasts onto your Shokz swim
> headphones by pasting a link. Free & open source 🏊‍♂️

**5 — Builder note**
> Weekend project: OpenShokz, a native macOS app that loads YouTube videos and
> podcasts onto Shokz swim headphones. Native downloader (no yt-dlp),
> sandboxed, auto-updates. Free & open source.

_Attach `og-motion.mp4` (or `og-b.png`) to options 1, 4, or 5; `og-c.png` pairs
well with the "for the pool" angle._
