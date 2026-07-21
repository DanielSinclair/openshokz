# Contributing

Development setup and the test commands live in the
[README](../README.md#development). This file covers the maintainer release
workflow.

## Cutting a release

Tag and push — the [Build DMG](workflows/build-dmg.yml) workflow packages the
styled drag-to-install DMG and attaches it (plus checksums) to the GitHub
release:

```bash
git tag v1.0.1
git push origin v1.0.1
```

Then finish the release:

1. Pin the DMG `sha256` in [`Casks/openshokz.rb`](../Casks/openshokz.rb) and
   sync the cask to
   [DanielSinclair/homebrew-tap](https://github.com/DanielSinclair/homebrew-tap)
   — a shared tap, reusable across projects.
2. Regenerate the Sparkle appcast locally (the EdDSA key lives in the login
   Keychain as “Private key for signing Sparkle updates”):
   `generate_appcast dist/` → merge into `site/appcast.xml` and deploy
   the site.
