# Phleet

**Phleet** is the native iOS client for the public [phleet](https://github.com/anurmatov/phleet)
platform. It connects to a **Fleet server profile that you supply at enrollment time**. No server
address of any kind ships in this repository or inside the app — a fresh install has nothing
configured, and says so on its first screen.

## No credentials live in this repository

This repository contains **no APNs key, no signing certificate, no provisioning profile, no App
Store Connect credential, and no deployment address or hostname**. Every one of those is
operator-owned, lives outside this repository, and is supplied to the release workflow at run time
as a secret or repository variable.

That is an enforced rule, not an intention: [`scripts/check-no-private-values.sh`](scripts/check-no-private-values.sh)
runs on every pull request and fails the build when a tracked file contains secret-shaped content, a
signing-material file extension, or an absolute address. Its patterns are generic — it deliberately
contains no list of real hosts, addresses, or identifiers, because publishing the list of things to
hide is itself the leak.

## Status — foundation only

This is the first slice. The app builds, launches, identifies itself, and shows a deliberately
non-functional enrollment entry point. It has:

- **no networking, no protocol client, no WebSocket or HTTP code**
- **no enrollment, authentication, token storage, or Keychain access**
- **no APNs registration** — the `aps-environment` entitlement is a static declaration and no code
  calls `registerForRemoteNotifications()`
- **no messaging, approvals, attachments, voice, or persistence of conversation content**

Those arrive in later slices, once this foundation is verified on real hardware.

## Build and test

Requires macOS with the pinned Xcode installed (see [docs/development.md](docs/development.md) for the
exact pins and how each one fails closed). There are no Swift package dependencies to resolve.

```
./scripts/bootstrap.sh   # verify the pinned Xcode, fetch + hash-verify the pinned XcodeGen
make generate            # produce Phleet.xcodeproj from project.yml (never committed)
make lint                # tracked-file invariant scan
make selftest            # exercise every gating script against fixtures
make test                # build and test on a simulator chosen by a deterministic rule
```

`Phleet.xcodeproj` is generated from [`project.yml`](project.yml) and is not committed. Do not hand-edit
a `.pbxproj`; change `project.yml` and regenerate.

## Repository layout

| Path | Contents |
|---|---|
| `Phleet/` | app sources, resources, entitlements |
| `PhleetTests/` | app-hosted unit tests |
| `PhleetUITests/` | one launch smoke test |
| `Config/` | `.xcconfig` build settings; local signing overrides are git-ignored |
| `scripts/` | build-gate scripts, each with a `--self-test` mode |
| `tests/fixtures/` | synthetic inputs for the script self-tests |
| `docs/` | toolchain, signing/release, and architecture notes |

## Documentation

- [docs/development.md](docs/development.md) — pinned toolchain and how to build without Xcode knowledge
- [docs/architecture.md](docs/architecture.md) — what this app is, what it is not, where the configuration seam is
- [docs/signing-and-release.md](docs/signing-and-release.md) — operator-owned signing and the TestFlight path
- [CONTRIBUTING.md](CONTRIBUTING.md) — how to work on this, and what must never be committed
- [SECURITY.md](SECURITY.md) — how to report a vulnerability

## License

[MIT](LICENSE). Copyright (c) 2026 Anvar Nurmatov.
