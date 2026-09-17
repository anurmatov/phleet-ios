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
2. Bootstrap the pinned toolchain
3. Create a temporary keychain, import the certificate, write the `.p8`, and install the
   provisioning profile. The profile's `UUID` and `Name` are decoded out of it with
   `security cms -D` rather than assumed: Xcode only finds a profile installed under its own
   `$UUID.mobileprovision`, and manual signing references it by `Name`
4. Generate `ExportOptions.plist` at run time (method `app-store-connect`, destination
   `upload`, `signingStyle` manual) including a `provisioningProfiles` entry mapping
   `com.anvarlab.phleet` to that profile name. It is git-ignored and scanned for
5. Archive with `CODE_SIGN_STYLE=manual`, `CODE_SIGN_IDENTITY="Apple Distribution"`,
   `PROVISIONING_PROFILE_SPECIFIER` set to the decoded name, and the build number from the run
   number. Manual signing selects nothing on its own — if the identity and profile are not
   handed to `xcodebuild` explicitly, both the archive and the export fail
6. Export and upload to App Store Connect with the API key
7. **Delete the keychain, the key, the profile and the export options** in an `if: always()`
   step, so a failed run leaves nothing behind

It is `workflow_dispatch`-only, it **uploads no artifact of any kind**, and it never falls back
to automatic signing or continues unsigned.

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
