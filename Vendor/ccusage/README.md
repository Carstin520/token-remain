# Bundled ccusage helper

TokenRemain bundles the official arm64 and x86_64 ccusage native helpers as one
Universal macOS executable, so website-distributed builds can read local usage
without requiring Node.js, npm, or a first-launch package download.

- arm64 package: `@ccusage/ccusage-darwin-arm64`
- x86_64 package: `@ccusage/ccusage-darwin-x64`
- Version: `20.0.33`
- Platform: Universal macOS (arm64 + x86_64), minimum macOS 14
- License: MIT; see `LICENSE`
- arm64 npm source: `https://registry.npmjs.org/@ccusage/ccusage-darwin-arm64/-/ccusage-darwin-arm64-20.0.33.tgz`
- x86_64 npm source: `https://registry.npmjs.org/@ccusage/ccusage-darwin-x64/-/ccusage-darwin-x64-20.0.33.tgz`
- arm64 SHA-256: `d88caeaa824d695acd2caa5ffacdf4326ef252c437c5eb7dfbd9af93705e120f`
- x86_64 SHA-256: `d8a33f2bc0b421f69263ca3c6283d4e9a534217ba7cfc74ee6aa498352daf124`
- Universal SHA-256: `e0d41cac2ff801121c018753086758800df6fb4ce9ca1ce45195f19642cfa4d0`

The release build copies the executable to `TokenRemain.app/Contents/Helpers`,
signs it with the same identity as the application, and verifies its version and
signature before packaging.

Before a release build, `script/verify_ccusage_freshness.sh --update` checks the
official npm `latest` metadata. If a newer stable package exists, the script
verifies both registry SHA-1 and SHA-512 integrity values, package identities,
platforms, architectures and versions before producing the Universal helper.
If a native package omits `LICENSE`, the script retrieves the MIT notice from
`https://registry.npmjs.org/ccusage/<same-version>`. That official wrapper must
pass the same SHA-1/SHA-512, package-name and exact-version checks; its license
must be MIT and its notice must be a unique, bounded regular archive member.
If these checks fail, the candidate is rejected and the verified bundled
helper is retained.
The release build then signs the helper together with TokenRemain.

Installed copies never check or advertise ccusage package versions. Usage
collection remains offline; when the helper has no price for a token-bearing
model, the UI reports that the price is unavailable instead of displaying a
misleading `$0.00`.
