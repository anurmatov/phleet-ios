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

## Status — enrollment and one thread

The app enrolls a device against a server you supply, shows the one agent that deployment binds,
opens a thread, sends messages, and renders what comes back.

What it does:

- **enrollment** — type the origin, paste the operator-issued code; the credential is persisted
  before the token mint is attempted, and re-presenting the same code overwrites a rotated secret
- **credentials** — one Keychain item, `AfterFirstUnlockThisDeviceOnly`, so it never migrates to a
  new device; the access token is held in memory only and refreshed on a monotonic deadline
- **one agent** — derived from `GET /v1/session`, because no route on the boundary enumerates
  agents
- **one thread** — stream attached first, then catch-up, with the live frames buffered in between;
  paging, history-gap separators, cursor advance, and every one of the eight close codes handled
  distinctly

What it still does not do:

- **no APNs registration** — the `aps-environment` entitlement is a static declaration and no code
  calls `registerForRemoteNotifications()`
- **no voice, attachments, approvals, or multi-agent rooms**
- **no steer or cancel interface** — the routes exist; this app does not surface them
- **no local persistence of conversation history** — the transcript is in memory only
- **no QR enrollment** — the operator's code-issuing path prints to a terminal, so there is
  nothing to scan yet

Every test is hermetic: nothing in the suite opens a socket, and it passes with the runner
offline. Nothing here has been exercised against a live server yet.

## Build and test

Requires macOS with the pinned Xcode installed (see [docs/development.md](docs/development.md) for the
exact pins and how each one fails closed). There are no Swift package dependencies to resolve.

```
./scripts/bootstrap.sh   # verify the pinned Xcode, fetch + hash-verify the pinned XcodeGen
make generate            # produce Phleet.xcodeproj from project.yml (never committed)
make lint                # tracked-file invariant scan + app icon gate
make selftest            # exercise every gating script against fixtures
make test                # build and test on a simulator chosen by a deterministic rule
make icon                # regenerate the committed app icon from its generator
```

`Phleet.xcodeproj` is generated from [`project.yml`](project.yml) and is not committed. Do not hand-edit
a `.pbxproj`; change `project.yml` and regenerate.

## Repository layout

| Path | Contents |
|---|---|
| `Phleet/` | app sources, resources, entitlements |
| `PhleetTests/` | app-hosted unit tests |
| `PhleetUITests/` | launch and conversation smoke tests, driven by an in-app scripted backend |
| `Config/` | `.xcconfig` build settings; local signing overrides are git-ignored |
| `scripts/` | build-gate scripts, each with a `--self-test` mode, plus the app-icon generator |
| `tests/fixtures/` | synthetic inputs for the script self-tests and recorded protocol event sequences |
| `docs/` | toolchain, signing/release, and architecture notes |

## Documentation

- [docs/development.md](docs/development.md) — pinned toolchain and how to build without Xcode knowledge
- [docs/architecture.md](docs/architecture.md) — the layers, the transport seam, the cursor rules, and the sign-out rule
- [docs/signing-and-release.md](docs/signing-and-release.md) — operator-owned signing and the TestFlight path
- [CONTRIBUTING.md](CONTRIBUTING.md) — how to work on this, and what must never be committed
- [SECURITY.md](SECURITY.md) — how to report a vulnerability

## License

[MIT](LICENSE). Copyright (c) 2026 Anvar Nurmatov.
