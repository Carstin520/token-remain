# Bundled ccusage helper

TokenRemain bundles the official arm64 and x86_64 ccusage native helpers as one
Universal macOS executable, so website-distributed builds can read local usage
without requiring Node.js, npm, or a first-launch package download.

- arm64 package: `@ccusage/ccusage-darwin-arm64`
- x86_64 package: `@ccusage/ccusage-darwin-x64`
- Version: `20.0.31`
- Platform: Universal macOS (arm64 + x86_64), minimum macOS 14
- License: MIT; see `LICENSE`
- arm64 npm source: `https://registry.npmjs.org/@ccusage/ccusage-darwin-arm64/-/ccusage-darwin-arm64-20.0.31.tgz`
- x86_64 npm source: `https://registry.npmjs.org/@ccusage/ccusage-darwin-x64/-/ccusage-darwin-x64-20.0.31.tgz`
- arm64 SHA-256: `fdec60203b05f3331deae72850d40ea6d948a0ae3e8cfb7e3b0a104a3b0f32bb`
- x86_64 SHA-256: `b64995b6eb198c53bbf19142c06d0c9c2c2be931e8db873d53e0aeeed00cebd1`
- Universal SHA-256: `4acccd8aaecfb56528ce406caaba9228342554eb3418b9f5656c0e2ac386a13d`

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
