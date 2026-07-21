# Bundled binaries

Run from the repo root:

```bash
./scripts/fetch-binaries.sh
```

This downloads a **universal** static `ffmpeg` (arm64 + x86_64 from [Martin Riedl's build server](https://ffmpeg.martin-riedl.de/)) into this folder. It is copied into the app bundle at build time and is gitignored (large).

Apple Silicon builds must ship a native arm64 `ffmpeg` slice. The old evermeet.cx build was Intel-only and triggered macOS “App Update Required” warnings for macOS 28 compatibility.
