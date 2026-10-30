# Bundled ccusage helper

TokenRemain bundles the official arm64 and x86_64 ccusage native helpers as one
Universal macOS executable, so website-distributed builds can read local usage
without requiring Node.js, npm, or a first-launch package download.

- arm64 package: `@ccusage/ccusage-darwin-arm64`
- x86_64 package: `@ccusage/ccusage-darwin-x64`
- Version: `20.0.45`
- Platform: Universal macOS (arm64 + x86_64), minimum macOS 14
- License: MIT; see `LICENSE`
- arm64 npm source: `https://registry.npmjs.org/@ccusage/ccusage-darwin-arm64/-/ccusage-darwin-arm64-20.0.45.tgz`
- x86_64 npm source: `https://registry.npmjs.org/@ccusage/ccusage-darwin-x64/-/ccusage-darwin-x64-20.0.45.tgz`
- arm64 SHA-256: `aa60cf1a76f772779449658b6b09be8361591a067dafc6997e7f4135af650532`
- x86_64 SHA-256: `eba9363566aaf962024906e1677d7e445d1102e553b32eb851980f610ff968f7`
- Universal SHA-256: `96d4fa7024a27cad4dec700b1f0ae4757167b81dac13ca1d7d66c4042eaefdb0`

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
