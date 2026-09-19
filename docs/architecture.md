# Architecture

One page. Most of what matters here is which decisions are load-bearing, and why the obvious
simplification of each one fails quietly.

## What it is

A native iOS client for the public [phleet](https://github.com/anurmatov/phleet) platform,
targeting iOS 17.0 and built with SwiftUI.

It enrolls a device against a server you supply, shows the one agent that deployment binds, opens
a thread, sends messages, and renders what comes back. The wire contract is
[`docs/first-party-api.md`](https://github.com/anurmatov/phleet/blob/main/docs/first-party-api.md)
(the north boundary) and
[`docs/conversation-protocol.md`](https://github.com/anurmatov/phleet/blob/main/docs/conversation-protocol.md)
(the event envelope). Nothing here redesigns either.

## What it is not

Not in this slice, and not partially present either:

- no APNs registration; the `aps-environment` entitlement is a static declaration and nothing
  calls `registerForRemoteNotifications()`
- no voice, attachments, approvals, or multi-agent rooms
- no steer or cancel interface — the routes exist, this app does not surface them
- no local persistence of conversation history: no database, no file store, no user defaults
- no QR enrollment

The app also ships **no server address**. There is no `Info.plist` key, no `.xcconfig` key, and
no source literal holding a host.

## Layers

```
Phleet/
  PhleetApp.swift              @main entry
  App/
    AppEnvironment.swift       composition root; routing; the composer draft
    LaunchDouble.swift         launch-argument-selected scripted backend, for the UI smoke test
  Protocol/                    the wire: envelope, kinds, payloads, request/response bodies
  Networking/                  URLSession and URLSessionWebSocketTask behind two protocols
  Credentials/                 device credential at rest; the access token in memory
  Enrollment/                  register → mint → session, and the screen
  Agents/                      the single session-derived agent entry
  Conversation/                attach, catch up, buffer, send, render
  Configuration/               server profile: model, store seam, resolution
  Support/                     accessibility identifiers, launch arguments
  Resources/                   string catalog, asset catalog
```

## The configuration seam

```
AppEnvironment                       composition root, constructed once in PhleetApp
  ├── ServerProfileResolution.resolve(store:launchEnvironment:overrideAllowed:)
  │     └── CredentialBackedServerProfileStore   the profile is whatever the credential says
  ├── CredentialStore                KeychainCredentialStore in the app
  ├── FleetAPIClient                 the seven HTTPS routes
  └── ConversationStream             one connection, expressed as a sequence
```

`ServerProfileResolution` is **unchanged** by this slice. Enrollment replaced the store, which is
exactly what the seam existed for.

### Why `resolve` takes a `Bool` instead of reading a compile-time flag

`resolve` is a pure function. The single `#if DEBUG` in the entire codebase lives in one property,
`ServerProfileResolution.overrideAllowedForCurrentBuild`, which `AppEnvironment` is the only
reader of. That shape is what makes "a release build ignores `PHLEET_SERVER_URL`" testable:
unit-test bundles build Debug regardless of scheme, so a branch compiled out of the test run could
never be falsified. `make lint` fails the build on a second build-gate branch anywhere under
`Phleet/`.

The UI smoke test's scripted backend is selected by a **launch argument**, not a build gate, for
the same reason — and so the test drives the app exactly as built.

## The transport seam

Two protocols, and the tests drive both:

- `FleetAPIClient` — the seven HTTPS routes. `origin` is a parameter rather than state, because
  enrollment happens before there is a stored profile.
- `ConversationStream` — one connection as an `AsyncStream` of `hello`, events and a close code.
  `ping` never crosses it: the implementation answers with `{"kind":"pong"}` and nothing above
  needs to know liveness exists.

Every test in the suite is hermetic. A scripted double yields `hello`, some events and a close
code with no socket anywhere, which is what lets each of the eight close-code behaviours be
asserted without a network.

## Decisions worth knowing

### `protocol` is on every request body, from one constant

The server compares the field ordinally and rejects `null`, on every route including enrollment.
Every request type in `WireBodies.swift` declares it as a `let` with a fixed value, which keeps it
out of the memberwise initializer: no call site can omit it, so this is a property of the types
rather than a review checklist.

### Three cursor values, one definition site

`afterSeq` means the same thing on the catch-up call and the stream upgrade — "I have processed up
to and including this seq" — and the two are computed from *different* sources.

| Name | Value | Used for |
|---|---|---|
| cold-start cursor | `0` | the first catch-up of a session with no stored cursor |
| recovery floor | `max(retainedFloorSeq, 1) − 1` | the catch-up after `invalid_cursor` |
| live-tail floor | `max(nextSeq, 1) − 1` | **every** stream upgrade, always |

All three live in `Conversation/StreamAttachFloor.swift` and are written as arithmetic nowhere
else. The stream's value is constant across cold start, resume and recovery because a stream is
never a request for history: the server's tail replays every committed event from whatever floor
it is given into a bounded, non-blocking 256-slot buffer, and it starts that replay *before*
sending `hello`. Handing it a history cursor closes `4413` deterministically on any conversation
with more than 256 retained events — and the documented `4413` response, reconnect and catch up,
reattaches at the same floor and loops forever.

### Stream first, then catch up

The stream is attached and `hello` received **before** catch-up is issued. Catch-up-then-attach
leaves an interval between the read and the upgrade in which appended events belong to neither,
and the client cannot tell a quiet interval from a lossy one. Buffering from `hello` onward means
there is no interval at all, and one code path serves first connect, clean resume and post-`4413`
recovery alike.

The client's own buffer is bounded at the server-reported `outboundBufferEvents`. On overflow it
discards the whole buffer and schedules one more catch-up round rather than dropping frames: a
dropped frame is the one failure it could never detect.

Dedupe is on `eventId`, not `seq`, because `conversation.replay_gap` carries `seq: null`.

### A terminal closes every submission it lists

A submission folded into a running turn — `submission.accepted { disposition: "injected" }` — or
coalesced at turn start **never** receives a terminal whose `identity.submissionId` is its own.
`mergedSubmissionIds[]` is what closes it. `turn.error` and `turn.outcome_unknown` carry no merged
list at all, so the host turn's terminal closes everything attached to that turn.

The invariant the implementation states: **no submission is ever left working with no path to a
terminal.**

### `turn.outcome_unknown` is a third state

Not success, not failure, and never an unresolved spinner. The work may have run in full, in part,
or not at all. Its action is labelled "Send again" rather than "Retry", and it is the single place
a resend mints new identifiers — everywhere else a retry reuses the same `submissionId` and
`idempotencyKey`, because a non-2xx means "not known to have happened", not "did not happen".

### The sign-out rule

Every auth failure is indistinguishable by contract, so a `401` carries no information about
whether the token merely expired or the device was revoked. The only way to tell is to spend the
device credential and see what happens.

| Event | Behaviour |
|---|---|
| `401` on any authenticated route except the token mint | mint once, replay the request once, do not sign out |
| WebSocket close `4401` | mint, reconnect, catch up; the first occurrence does not count against backoff |
| **`401` from `POST /v1/auth/token`** | **the only sign-out.** Delete the credential, clear the token and transcript, return to enrollment |

`AccessTokenHolder` owns that rule and is the only place in the app that deletes the credential.
The composer draft lives on `AppEnvironment`, above everything sign-out tears down, so signing out
cannot silently discard a message someone typed.

### Credential storage

One Keychain item holding `{ origin, deviceId, deviceSecret, clientInstanceId }` as JSON, with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.

`AfterFirstUnlock` so a reconnect can read it with the screen locked. `ThisDeviceOnly` is the
load-bearing half: it excludes the item from iCloud Keychain and encrypted backups, so a restore
to a new device arrives with **no** credential — which is what the contract requires, since a
secure-store loss is recovered by revoke-and-re-enroll, never a silent re-issue.

The access token is never persisted. It is derivable from the credential at any time, and storing
it would add a second secret at rest to save one round trip per fifteen minutes. Deadlines are
measured on a monotonic clock, so a backward wall-clock jump cannot extend a token's apparent
life.

### One agent, because the API says so

There is no agent-list route on the north boundary. `GET /v1/session` returns a single
`agentLabel`, and the deployment binds exactly one agent name. So this renders one entry, not a
one-row list with a selection model that would have to be rebuilt when the real shape lands.
`agentLabel` is cosmetic and non-authoritative; nothing routes on it.

## Accessibility

`AccessibilityIdentifier` is a `CaseIterable` enum holding every element the interface exposes.
Each case carries both the UI-test hook (`identifier`) and the spoken label (`localizedLabel`),
resolved from the app bundle's string catalog under the fixed convention `"a11y." + rawValue`.
A new case with no catalog entry fails the build with no new test needed.

Each transcript entry is a **single** accessibility element reading one coherent sentence —
speaker, state, text. Terminals post an announcement, and `turn.outcome_unknown` must: a spinner
that quietly stops is unreadable to VoiceOver, and that is exactly the misread that ends with
someone re-running work that already ran.

Every font is a semantic text style. Rows that cannot fit at accessibility sizes reflow vertically
rather than truncating, and the working indicator becomes a static labelled state under Reduce
Motion. Success, error and `outcome_unknown` each carry a symbol as well as a colour, because that
three-way distinction is the safety-critical one.

`PhleetTests` is **app-hosted**. In a non-hosted logic bundle `Bundle.main` is the xctest runner,
the app's catalog is not in it, every lookup returns its own key, and the whole accessibility
suite would pass while proving nothing.
