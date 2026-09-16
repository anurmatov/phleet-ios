# Architecture

One page. This app is small on purpose, and most of what matters is what it deliberately does
not do yet.

## What it is

A native iOS client for the public [phleet](https://github.com/anurmatov/phleet) platform,
targeting iOS 17.0 and built with SwiftUI.

Today it launches, says what it is, and offers a single entry point that explains enrollment has
not arrived yet.

## What it is not

Not in this slice, and not partially present either — none of this code exists:

- no networking of any kind: no HTTP client, no WebSocket, no protocol client
- no enrollment, authentication, or token storage
- no Keychain access
- no APNs registration; the `aps-environment` entitlement is a static declaration and nothing
  calls `registerForRemoteNotifications()`
- no messaging, approvals, attachments, voice, or rooms
- no persistence of conversation content — no database, no file store, no user defaults

The app also ships **no server address**. There is no `Info.plist` key, no `.xcconfig` key, and
no source literal holding a host.

## The configuration seam

The one piece of structure worth knowing, because everything later hangs off it.

```
AppEnvironment                     composition root, constructed once in PhleetApp
  └── ServerProfileResolution.resolve(store:launchEnvironment:overrideAllowed:)
        ├── ServerProfileStore      where an enrolled profile would come from
        └── FleetServerProfile      a validated https address with a host
```

Resolution precedence is: whatever the store holds, then a launch-environment override if this
build allows one, then nothing.

`InMemoryServerProfileStore` always returns `nil`, so this build always resolves to the
unenrolled state. The slice that adds enrollment replaces the store and leaves resolution
untouched.

### Why `resolve` takes a `Bool` instead of reading a compile-time flag

`resolve` is a pure function. The `overrideAllowed` argument is a plain value, and the single
`#if DEBUG` in the entire codebase lives in one property,
`ServerProfileResolution.overrideAllowedForCurrentBuild`, which `AppEnvironment` is the only
reader of.

That shape exists so the rule "a release build ignores `PHLEET_SERVER_URL`" is testable. Had the
branch lived inside the resolution logic, the release path would be compiled out of every test
run — unit test bundles build Debug regardless of scheme — and the assertion covering it could
never have failed. `make lint` enforces the invariant: more than one build-gate branch under
`Phleet/`, or one outside that file, fails the build.

### Validation

`FleetServerProfile.init` rejects anything that is not `https`, carries no host, or embeds
user-info, throwing a typed `FleetServerProfileError`. It never traps: every address that
reaches it is user input, so a bad one is an ordinary outcome to report.

The debug override goes through exactly the same validation, so it cannot be used to reach a
destination a user-supplied address could not.

## Accessibility

`AccessibilityIdentifier` is a `CaseIterable` enum holding every element the interface exposes.
Each case carries both the UI-test hook (`identifier`) and the spoken label
(`localizedLabel`), resolved from the app bundle's string catalog under the fixed key
convention `"a11y." + rawValue`.

Views and tests read the same `localizedLabel` property, so there is one resolution path and the
launch smoke test and the catalog test cannot disagree about what a label says.

`PhleetTests` is **app-hosted**. In a non-hosted logic bundle `Bundle.main` is the xctest runner,
the app's catalog is not in it, every lookup returns its own key, and the whole accessibility
suite would pass while proving nothing.

## Layout

```
Phleet/
  PhleetApp.swift              @main entry
  App/AppEnvironment.swift     composition root
  Configuration/               server profile: model, store seam, resolution
  Views/                       RootView, EnrollmentPlaceholderView
  Support/                     AccessibilityIdentifier
  Resources/                   string catalog, asset catalog
  Info.plist, Phleet.entitlements
```
