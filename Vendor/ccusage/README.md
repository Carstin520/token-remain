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
