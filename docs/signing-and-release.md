# Signing and release

Everything on this page is operator-owned. **None of these values is in this repository, and
none may ever be committed.** They are supplied to `release.yml` at run time as GitHub secrets
and repository variables.

## The signing model

Manual signing (`CODE_SIGN_STYLE=manual`) with an App Store Connect API key, into an ephemeral
keychain that is created and destroyed inside the job.

Manual, not automatic, because automatic signing needs an interactive Apple ID session on the
machine — which a runner does not have, and which would make the job depend on state outside the
workflow. The keychain is ephemeral because a distribution identity left behind on a runner is a
credential lying around on a shared machine.

## Release inputs

`release.yml` runs `scripts/check-release-inputs.sh` before it creates anything. A missing or
empty input stops the run there, naming every input that is absent, rather than failing
half-way through building a keychain.

| Input | Kind | Purpose |
|---|---|---|
| `APP_STORE_CONNECT_KEY_ID` | secret | App Store Connect API key identifier |
| `APP_STORE_CONNECT_ISSUER_ID` | secret | App Store Connect issuer identifier |
| `APP_STORE_CONNECT_PRIVATE_KEY` | secret | base64-encoded `.p8` |
| `DISTRIBUTION_CERTIFICATE_P12` | secret | base64-encoded distribution certificate |
| `DISTRIBUTION_CERTIFICATE_PASSWORD` | secret | password for the certificate above |
| `PROVISIONING_PROFILE` | secret | base64-encoded `.mobileprovision` |
| `KEYCHAIN_PASSWORD` | secret | password for the temporary keychain the job creates and deletes |
| `DEVELOPMENT_TEAM` | repository variable | Apple team identifier, supplied at run time |

`DEVELOPMENT_TEAM` is a repository *variable* rather than a secret because a team identifier is
not a credential — but it is still an operator-owned value about a real account, so it is
supplied at run time and never committed. `Config/Signing.example.xcconfig` holds only
placeholders.

The self-test proves this list is real: `scripts/check-release-inputs.sh --self-test` runs the
script under `env -i` and asserts it exits 1 naming exactly these eight.

## What the release job does

1. Check out, then **check the inputs** — nothing is created before this passes
2. **Check the app icon** — see below; also before anything is created
3. Bootstrap the pinned toolchain
4. Create a temporary keychain, import the certificate, write the `.p8`, and install the
   provisioning profile. The profile's `UUID` and `Name` are decoded out of it with
   `security cms -D` rather than assumed: Xcode only finds a profile installed under its own
   `$UUID.mobileprovision`, and manual signing references it by `Name`
5. Generate `ExportOptions.plist` at run time (method `app-store-connect`, destination
   `upload`, `signingStyle` manual) including a `provisioningProfiles` entry mapping
   `com.anvarlab.phleet` to that profile name. It is git-ignored and scanned for
6. Archive with `CODE_SIGN_STYLE=manual`, `CODE_SIGN_IDENTITY="Apple Distribution"`,
   `PROVISIONING_PROFILE_SPECIFIER` set to the decoded name, and the build number from the run
   number. Manual signing selects nothing on its own — if the identity and profile are not
   handed to `xcodebuild` explicitly, both the archive and the export fail
7. Export and upload to App Store Connect with the API key
8. **Delete the keychain, the key, the profile and the export options** in an `if: always()`
   step, so a failed run leaves nothing behind

It is `workflow_dispatch`-only, it **uploads no artifact of any kind**, and it never falls back
to automatic signing or continues unsigned.

### Why the icon is checked before the toolchain

The first real release run archived and signed cleanly and was then rejected by App Store
Connect: `90713` for a missing `CFBundleIconName` and `90022` for a missing 120×120 icon. The
project already declared `ASSETCATALOG_COMPILER_APPICON_NAME`, but the icon set referenced no
file, so `actool` compiled an empty set, emitted no icon metadata, and nothing in the build said
so. Neither archiving nor signing can catch that — only the upload can, which is the most
expensive place in the pipeline to find out.

`scripts/check-app-icon.sh` moves the failure to the front. It asserts that `Contents.json` names
a file, that the file exists, that it really is a PNG by signature and `IHDR`, that it is exactly
1024×1024, that it carries **no transparency in any form** — a transparent icon is rejected at the
same stage, so accepting one would trade this rejection for a different one — and that the mark
**still holds together at 40×40**, by decoding it, box-filtering through actool's 25.6:1 ratio and
counting connected regions of ink against a committed expected count. The same gate runs
in pull-request CI via `make lint`, so a change that breaks the icon fails in seconds instead of on
the next release.

"No transparency" is an allowlist plus a chunk scan, and the distinction matters. An earlier
revision of the gate said "no alpha channel" and implemented it as a denylist of the colour types
that have one. That is the obvious reading and it is wrong: a palette image has no alpha *channel*
and is still transparent if it carries a `tRNS` chunk, and a fully transparent 1024×1024
palette+`tRNS` PNG passed the gate while this paragraph claimed it could not. The gate now requires
PNG colour type 0 or 2 — the only two that cannot carry alpha — and rejects `tRNS` wherever it
appears, including on those two types, where it marks one grey level or one RGB value fully
transparent. `tests/fixtures/appicon/palette-trns/` is that transparent icon, kept as a fixture so
the hole cannot reopen.

The 40×40 region count is there because "valid PNG of the right size" says nothing about whether
the artwork survives being seen. Thin strokes grey out and fragment at icon size, and a mark that
breaks into specks there passes every other check in this gate. `tests/fixtures/appicon/fragmented/`
is a perfectly valid 1024×1024 opaque PNG that is three disconnected pieces at 40×40, kept so the
rule is one that has been watched failing rather than one merely written down.

### Why no artifact

Artifacts on a public repository are publicly downloadable by anyone. This job handles a
distribution certificate and produces a signed build; neither belongs in a public artifact. The
`.xcresult` bundle from pull-request CI is a different matter — that job holds no secrets at all.

## Operator checklist

These cannot be done by a pull request. Someone with repository admin and an Apple Developer
account has to do them.

### Repository settings

- [ ] Enable **secret scanning** and **push protection** (Settings → Code security)
- [ ] Add the seven secrets above (Settings → Secrets and variables → Actions → Secrets)
- [ ] Add `DEVELOPMENT_TEAM` as a repository **variable**, not a secret
- [ ] Confirm `ci.yml` still passes on a pull request from a fork — it must, because it
      references no secret at all

### Apple

- [ ] App Store Connect API key created, with a role that can upload builds
- [ ] An **Apple Distribution** certificate and an App Store provisioning profile for
      `com.anvarlab.phleet`. The certificate type matters: the archive step passes
      `CODE_SIGN_IDENTITY="Apple Distribution"`, so a legacy `iPhone Distribution` identity
      fails to match
- [ ] The app record exists in App Store Connect
- [ ] An APNs key exists for later slices — **it is not used by any code in this repository yet**

### Local signed build

- [ ] `cp Config/Signing.example.xcconfig Config/Signing.local.xcconfig` and fill it in
- [ ] `./scripts/bootstrap.sh && make generate`
- [ ] Build to a physical device from Xcode

## Operator gates — not claimed by any pull request

CI cannot establish any of the following, and a pull request that reports them as passing is
making a false claim. They are verified by a person, on hardware:

- a local signed build on the operator's Mac
- a real `release.yml` run with all eight inputs present, producing a private TestFlight build
- VoiceOver navigation and Dynamic Type rendering at `.accessibility3` and above on a device
