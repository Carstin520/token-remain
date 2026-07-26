# Bundled ccusage helper

TokenRemain bundles the official `@ccusage/ccusage-darwin-arm64` native helper so
website-distributed builds can read local usage without requiring Node.js, npm,
or a first-launch package download.

- Package: `@ccusage/ccusage-darwin-arm64`
- Version: `20.0.18`
- Platform: macOS arm64, minimum macOS 14
- License: MIT; see `LICENSE`
- npm source: `https://registry.npmjs.org/@ccusage/ccusage-darwin-arm64/-/ccusage-darwin-arm64-20.0.18.tgz`
- SHA-256: `3179f6cabbd4bafe55946f2013c9e2ec3cdfb59fd8c152f3d2f3c7f2adaac6c5`

The release build copies the executable to `TokenRemain.app/Contents/Helpers`,
signs it with the same identity as the application, and verifies its version and
signature before packaging.

At runtime TokenRemain checks the official npm `latest` metadata every six
hours (and on a manual refresh). This metadata-only request never includes local
usage logs. Developer ID packaging also runs `script/verify_ccusage_freshness.sh`
and fails closed if the signed helper is older than the official latest package.
Usage collection itself remains offline; when the helper has no price for a
token-bearing model, the UI reports that the price is unavailable instead of
displaying a misleading `$0.00`.
