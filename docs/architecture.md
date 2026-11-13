# Architecture

One page. Most of what matters here is which decisions are load-bearing, and why the obvious
simplification of each one fails quietly.

## What it is

A native iOS client for the public [phleet](https://github.com/anurmatov/phleet) platform,
targeting iOS 17.0 and built with SwiftUI.

It has three tabs over one sign-in. **Fleet** and **Runs** use the orchestrator's operator API:
what is waiting for a person, how every agent is doing, and the workflow runs in progress and
recently closed. They are described under [The control plane](#the-control-plane). **Chat** lists
the agents that have chat turned on and keeps one thread with each: it opens the thread, sends
messages, and renders what comes back. All three reach the server through one address — the
dashboard's, which carries the orchestrator's `/api/` and the chat service's `/v1/` — with one
credential; see [One sign-in](#one-sign-in). For the thread, the wire contract is
[`docs/first-party-api.md`](https://github.com/anurmatov/phleet/blob/main/docs/first-party-api.md)
(the north boundary) and
[`docs/conversation-protocol.md`](https://github.com/anurmatov/phleet/blob/main/docs/conversation-protocol.md)
(the event envelope). Nothing here redesigns either.

## What it is not

Not in this slice, and not partially present either:

- no opening a thread from a notification: a reply's notification opens the Chat tab
- no voice, attachments, or multi-agent rooms
- no steer or cancel interface — the routes exist, this app does not surface them
- no local persistence of conversation history: no database, no file store, no user defaults
- no setup without a camera: the dashboard shows the setup code only as a QR code
- no provisioning, no terminate or restart of a run, and no editing of instructions, contexts,
  workflow definitions or secrets — those stay on the web dashboard

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
  Credentials/                 the sign-in at rest; the access token in memory; earlier builds' items
  Setup/                       scan → register → store → mint, and the screen
  Chat/                        the chat-enabled agents, and a thread model per agent
  Conversation/                attach, catch up, buffer, send, render (replies as Markdown)
  Control/                     the Fleet tab: orchestrator routes signed in, agents, gates, decisions
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
  ├── ControlAPIClient               the orchestrator's routes, sign-in included
  ├── FleetAPIClient                 the chat service's HTTPS routes
  └── ConversationStream             one connection, expressed as a sequence
```

`ServerProfileResolution` is **unchanged**. The sign-in credential is the store, which is exactly
what the seam existed for.

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

- `FleetAPIClient` — the chat service's HTTPS routes. The access token is a parameter; the access
  proxy's service token belongs to the address, so the real client is built with it at sign-in.
- `ConversationStream` — one connection as an `AsyncStream` of `hello`, events and a close code.
  `ping` never crosses it: the implementation answers with `{"kind":"pong"}` and nothing above
  needs to know liveness exists.

Every test in the suite is hermetic. A scripted double yields `hello`, some events and a close
code with no socket anywhere, which is what lets each of the eight close-code behaviours be
asserted without a network.

## Decisions worth knowing

### `protocol` is on every request body, from one constant

The chat service compares the field ordinally and rejects `null`, on every route.
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
| `401` on any authenticated route except the token mint | mint once, replay the request once, do not sign out; a second `401` is that request's failure |
| WebSocket close `4401` | mint, reconnect, catch up; the first occurrence does not count against backoff |
| **`401` from `POST /api/auth/token`** | **the only automatic sign-out.** Delete the credential, tear down Fleet, Runs and Chat, return to setup saying the phone was revoked |
| The person signs out | tell the orchestrator to forget this phone for notifications, revoke this device (`POST /api/auth/devices/{id}/revoke`), then delete the credential whatever the answers were — and say so when the server could not be told |

`AccessTokenHolder` owns the automatic rule and is the only place in the app that deletes the
credential on that path. It reads a `401` from either client the same way: the orchestrator's
(`ControlAPIError`) and the chat service's (`FleetAPIError`). Composer drafts live on
`AppEnvironment`, one per agent, above everything sign-out tears down, so signing out cannot
silently discard a message someone typed.

### Credential storage

One Keychain item holding `{ origin, accessClientId?, accessClientSecret?, deviceId, deviceSecret,
clientInstanceId, pushDeviceId? }` as JSON, with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.

`AfterFirstUnlock` so a reconnect can read it with the screen locked. `ThisDeviceOnly` is the
load-bearing half: it excludes the item from iCloud Keychain and encrypted backups, so a restore
to a new device arrives with **no** credential — which is what the contract requires, since a
secure-store loss is recovered by revoke-and-sign-in-again, never a silent re-issue.

The access token is never persisted. It is derivable from the credential at any time, and storing
it would add a second secret at rest to save one round trip per fifteen minutes. Deadlines are
measured on a monotonic clock, so a backward wall-clock jump cannot extend a token's apparent
life. The enrollment code is sent once and never stored.

The item is stored under a name no earlier build used. Earlier builds kept two items — a chat
credential for a sign-in the chat service no longer has, and a Fleet connection holding the
fleet-wide operator token — and `KeychainLegacyCredentialStore` deletes both at launch, keeping
only the identifier notifications were registered under, so the first sign-in to the same address
replaces that row on the orchestrator instead of adding a second one.

### A thread per agent

The agents come from the orchestrator (`GET /api/chat/agents`), which owns the per-agent chat
switch; `available: false` means the server has no chat service, and is said as that rather than
as an empty list. Each agent has one thread, opened with `externalRef: "main"` and the agent's
name: the chat service finds a conversation again by person, agent and reference, so the phone and
the dashboard open the same one. An agent has a single model context, so more than one thread
with it would look separate without being so.

`409 agent_unavailable` — chat turned off since the list was read — stops the thread's reconnect
loop and is said as itself, with a way to try again: asking again cannot change it, and the fix is
a switch in the agent's settings.

### An agent's reply is Markdown, and never HTML

`ReplyMarkdown` renders what one `Text` can show faithfully: inline syntax through
`AttributedString(markdown:)` with inline-only interpretation that preserves whitespace, and
fenced code blocks, which are split out first and shown verbatim. Full block parsing produces
presentation intents a `Text` does not lay out — paragraphs run together and list markers vanish —
so block syntax stays as typed. A tag is shown as its characters with the parser's HTML mark
removed, and a link is kept only for `http` and `https`. The person's own messages are plain text.

## One sign-in

The dashboard's address carries both servers: its proxy sends `/api/` and `/ws` to the
orchestrator and `/v1/` to the chat service. The orchestrator owns sign-in, and the chat service
asks it who a caller is, so one access token is good for both.

```
setup code (QR) ── POST /api/auth/devices ──▶ { deviceId, deviceSecret }  stored
                   POST /api/auth/token   ──▶ { accessToken, 15 min }     memory only
every request ───── Authorization: Bearer <accessToken>   (+ the proxy's service token)
```

### A setup code shows the address and never connects

The dashboard draws a JSON object as a QR code:
`{"phleet":"setup","v":2,"origin":…,"accessClientId"?,"accessClientSecret"?,"enrollmentCode":…}`.
`SetupCode.parse` reads it as untrusted input:

- The kind and the version are checked before anything else is read. Some other QR code is "not
  a setup code"; another version is refused by name rather than read with today's field names.
- The kind an older dashboard drew (`control-setup`, carrying the operator token) is refused by
  name, with where to make a new code. Nothing in it is read.
- The address passes the same rule as any other — `https`, a host, no user name or password — and
  is shown for a person to check. Connecting is a separate tap.

The camera is `DataScannerViewController`, restricted to QR codes, in a sheet that hands back the
first code's text and nothing else. Camera access is asked for when the sheet opens, never at
launch. A simulator has no camera, so under the scripted backend the scan button applies a fixed
code instead of opening one; that is what the UI tests drive, and it means **the camera path
itself is not covered by CI**.

### Registering stores before it mints

The orchestrator commits the device before it can know its answer arrived, so the credential is
stored before the first token is asked for. Presenting the same code again before that first
token answers with the same device and a rotated secret, which overwrites the stored one and keeps
its cursor bookkeeping. A first token that cannot be had that minute does not undo the sign-in —
the code is spent, and the token is asked for again when it is needed — but a first token the
orchestrator refuses does.

## The control plane

```
AppEnvironment
  ├── ControlAPIClient              the orchestrator routes this app uses
  ├── SignedInControlAPI            the same routes, each request carrying a current token
  ├── ControlLiveStream             the orchestrator's state socket, as a sequence
  ├── AgentLogStream                one agent's log socket, as a sequence
  ├── ControlPlaneModel             agents, runs in progress, gates, agent actions
  └── RunsModel                     closed runs, run history, cancel, start
```

The models exist exactly when a sign-in does and are torn down with it. Runs in progress live only
in `ControlPlaneModel`, which already keeps them fresh; `RunsModel` holds what changes slowly and
is read on demand. One run never has two states that could disagree.

### Every request is signed in

Through the dashboard's address the orchestrator answers nothing without a credential, reads
included, so `ControlRequest.make` puts the access token on every request that has one, and the
access proxy's service token on every request. The models hold a connection with no token in it;
`SignedInControlAPI`, `SignedInControlLiveStream` and `SignedInAgentLogStream` put a current one on
each request or socket as it goes out. The only requests built without one are the two that
obtain one. Neither secret ever appears in a URL.

There is no read-only connection any more: a signed-in phone may do what the operator API offers,
except manage other devices and read configuration values, which the orchestrator refuses a
phone's token.

### Notifications are three steps, and each can say no

Turning notifications on needs the person's permission, a device token from Apple, and the
orchestrator accepting that token. `PushNotificationsModel` gives every way one of them stops its
own state, because each is fixed somewhere different: Settings, the network or the build's
signing, or the orchestrator's configuration.

- **The wish is stored with the sign-in**, as `pushDeviceId` on `DeviceCredential`, and it is
  stored before the token arrives. It then survives a launch in which Apple or the orchestrator
  could not be reached, and the next launch asks Apple again, because a token can change.
- **An orchestrator that will not send is never shown as "on".** `503 push_disabled` and a
  missing route both clear the wish and say which it was.
- **Turning off stops the phone first.** The app unregisters with the system whether or not the
  orchestrator could be told to forget the device.
- **A registration that finishes late changes nothing.** The wish changes before anything is
  awaited, and a registration answered after it has changed — turned off, turned on again, or sent
  again with a newer token — cannot turn notifications back on, show a stale failure or clear the
  newer wish. If the orchestrator accepted it for a device no longer wanted, the app tells it to
  forget that device again. A new wish always gets a new device identifier, so this never removes
  it. Registrations go one at a time, so the orchestrator stores tokens in the order Apple issued
  them; one overtaken while it waits is not sent.
- **Signing out forgets the phone first.** The orchestrator is told to forget it while there is
  still a sign-in to say so with; a phone revoked from the dashboard cannot say anything, so it
  stops receiving on its own and Apple tells the orchestrator the token is gone.
- **Permission is asked for from the connection sheet**, in answer to a tap, never at launch.

The system side sits behind `PushSystem`. The real one, `SystemPushSystem`, is a single object
because the application delegate and the notification-centre delegate are created by the system
and have nothing else to report to. Most tapped notifications select the Fleet, Runs or Chat tab;
an unknown kind opens Fleet rather than nothing.

A `gate` notification for `request-input` may also carry namespace, workflow, run and signal
identity. The app refreshes Fleet and opens only the matching pending human-input request.
Missing fields, stale runs and missing matches leave the person on the list. The push supplies
no question, context or answer, and never permission to send. A later navigation visit or a
different sign-in invalidates an older lookup; changing the control-plane session clears the
Fleet navigation path.

The app holds no key. The orchestrator signs and sends; see `docs/push-notifications.md` in the
platform repository.

### No redirect is ever followed

An orchestrator never redirects. A proxy that does not recognise the caller does: it answers with
a redirect to a sign-in page. Following it would send the service-token headers to the next host
and return a web page where a list of agents was expected. `RedirectRefusingDelegate` refuses
every redirect, so the secrets stay on the origin they were stored for and "not let in" arrives
as a status this client can name — distinct from `401`, which means the orchestrator refused this
phone's sign-in. The session is ephemeral and keeps no cookies and no cache. The chat service is
reached through the same proxy on a session with the same rules, whose idle wait outlasts the
chat stream's twenty-second ping.

### HTTPS is the truth, the socket is the shortcut

`ControlPlaneModel` reads agents, runs and the signal registry over HTTPS every thirty seconds
while the screen is in use. The live socket applies the same facts sooner. Nothing depends on the
socket: whether it passes an access proxy with service-token headers is untested, and a control
plane that went blank when it did not would be worse than one thirty seconds behind.

A read **replaces** the agent list rather than merging into it, so an agent the orchestrator no
longer lists is gone. A failed read keeps what was on screen and says why it may be stale.

### What counts as waiting

A run is on the "needs you" list when it is running, reports a phase, and its workflow type
registers a signal that **names** that phase (`PendingGates.derive`). A signal with no phase list
is one the orchestrator accepts at any time; it says nothing about whether anyone is waiting, and
listing every such run would bury the ones that are.

### A decision is sent as it was shown

The gate screen holds the gate as it was tapped, and the request carries that snapshot's `runId`
and `expectedGateRef`. They are never refreshed on the way out: the orchestrator compares them
with the run's current state and answers `409` when the question on screen is no longer the
question being asked. The identifier of a gate includes its phase and gate reference, so a second
visit to the same gate is a new question and does not inherit "already answered".

A request that does not complete is `outcomeUnknown`, not a failure: it may have reached the
workflow. The model reads again, and the gate is either still there or gone.

Every decision takes two taps — choose, then send — because an approval sent by a thumb reaching
for something else cannot be undone from here.

### Human input loads the original exact request

`UweHumanInputWorkflow` uses the same gate screen, but not the registry's decision buttons.
`SignedInControlAPI.exactRunHistory` reads the original input with that gate's nonempty `runId`.
It never falls back to the latest run or the display history's lossy decoder. Missing, malformed,
duplicate-key or unknown-format input leaves the request unavailable, with no answer controls.
The [platform contract](https://github.com/anurmatov/phleet/blob/main/docs/human-input-requests.md)
defines the request and the server's human-only answer checks.

The screen shows Question, Context and requester identity literally. It preserves choice order
and sends a declared choice ID, raw multiline text, or the `approved`/`rejected` preset ID.
Selection and confirmation are separate taps. Value and optional Comment are kept unchanged,
with at most 2000 UTF-16 units each; a text answer must not be blank. An answer records data,
not authority to execute work or a replacement for a reserved approval gate.

Loading, a failed refresh, a replacement run or a superseded history read cannot send an answer.
The request carries the displayed `runId` and `expectedGateRef`. A stale or uncertain send
refreshes and reloads that same exact request without replaying the answer automatically.

### An action is "requested", and the state is the evidence

Restart, stop, start and cancel-task answer when the orchestrator has taken the request, not when
the agent has changed. The model records `requested`, reads the fleet again straight away, and
the agent detail screen renders the agent's **current** state from the model rather than the row
that was tapped — so what a person sees after a restart is the agent coming up, not a message
claiming it did.

Which actions are offered follows the agent's state (`AgentAction.available(for:)`). An agent
with no heartbeat is offered restart rather than start: "no heartbeat" may mean hung or stopped,
and a restart is right for both.

### A cancel names the run

`cancelRun` sends the run identifier as well as the workflow identifier. A workflow restarted
under the same name is a different run, and a screen still showing the old one must not cancel
the new one.

### A log is a tail, and it does not silently resume

`LogTail` keeps the newest five hundred lines and counts what fell off the front, so the screen
can say that the top is not the beginning. When the socket ends the log stops and says so;
following again is a reload, which starts from the orchestrator's replay. A log that reconnected
on its own would show a gap as if it were continuous.

### Starting offers only inputs a form can produce

A workflow type's inputs are read from its JSON Schema. Text, number and boolean properties
become fields; an array or a nested object is left out rather than rendered as a text box that
could only produce the wrong type. An optional input left empty is omitted from the request, not
sent as an empty string, so a workflow that tests "was this given" is not told yes.

### Decoding is forgiving, addressing is strict

`LossyList` keeps every element it can read. An agent needs only a name; any other field that is
absent or misshapen costs that field. A run needs its five identity fields, because a decision is
addressed to exactly one run and a run that cannot be addressed must not be offered one.

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
