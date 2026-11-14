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

- no widget and no share extension: both need their own targets, an App Group and provisioning
  profiles the operator creates
- no voice, no attachment other than an image, no image from an agent, no multi-agent rooms
- no steer interface — the route exists, this app does not surface it
- no local persistence of conversation history: no database, no file store, no user defaults —
  history, the person's own messages and images included, is read back from the server
- no provisioning of an agent that never was, and no editing of instructions, contexts, workflow
  definitions, schedules, memories or secrets — those stay on the web dashboard

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
  Control/                     Fleet and Runs: agents, gates, decisions, runs, schedules, memory
  Shortcuts/                   the two App Intents, and the screenless sign-in they share
  Configuration/               server profile: model, store seam, resolution
  Support/                     accessibility identifiers, launch arguments, the small
                               preference store, the owner check
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

### The person's own words come back from the server

A compatible chat service appends `submission.text` in the transaction that accepts a submission,
at the seq it reports as `acceptedSeq`, so the words sort before everything their turn produces
and are retained like any other durable event. The client reads them from the same catch-up and
stream as everything else and puts the text on the row its `identity.submissionId` names. Text is
all it sets: no state, no progress, no reply, and text arriving after a terminal changes nothing
the terminal decided.

The server keeps a submission under an id of its own; the receipt for a send names the id this
device chose. So a message sent here exists twice until something joins them, and the only thing
that does is the receipt's `acceptedSeq` matching the seq of a `submission.text` — whichever of
the two arrives second. Then the echo is retired and the durable row, which every later event
names, is the one shown. Nothing is matched by text, which two submissions may share, or by time.

| Case | Behaviour |
|---|---|
| `201` with `acceptedSeq` | joins its `submission.text`, before or after that event arrives |
| `202`, no `acceptedSeq` | already durable: the echo is retired, the transcript's row stands, and no seq is invented |
| no receipt (transport failure) | the echo stays, unconfirmed, until a retry's receipt resolves it; the retry reuses the same ids |
| "Send again" on a joined row | follows the link to what this device sent, as a new submission with new ids |
| "Send again" on a restored row | nothing: no send of this device's is behind it, and reading history never submits |

A row with no `submission.text` says **Message text unavailable** where the words would be, and
keeps its reply and status. That covers conversations from before the server kept the text and
messages beneath the retained floor, where the existing gap separator says history was pruned;
nothing is backfilled, guessed from the reply, or offered for resending. A message sent with no
text says so differently, because it is a different fact. A `submission.text` without a string
`text`, or naming no submission, is counted with the other ignored events and erases nothing.

This needs a chat service that writes `submission.text`, as public phleet does from
[`cb6153f`](https://github.com/anurmatov/phleet/blob/cb6153f2cac04521916ce61706f8a7641b3c6443/docs/conversation-protocol.md#submissiontext--the-users-own-messages-are-part-of-the-log-305).
Against one that does not, every restored row reads as unavailable. The scripted backend writes
durable ids distinct from the app's, so its UI tests take the same route; no installed server has
been checked by this client.

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

`ReplyMarkdown` renders what a column of `Text` can show faithfully. Inline syntax goes through
`AttributedString(markdown:)` with inline-only interpretation that preserves whitespace. Its full
block parsing produces presentation intents a `Text` does not lay out — paragraphs run together
and list markers vanish — so block syntax is read here a line at a time and written back as text:
a heading becomes strong text, a list item keeps its indentation and gets a bullet or a task box,
a quote gets a bar, a rule becomes a line. Every line of the reply is still one line of the
result. Fenced code blocks and tables are split out and laid out on their own
(`MarkdownBlocksView`): code verbatim on its own ground, a table as a grid whose every row has
the header's columns.

Nothing in a reply scrolls sideways. A long line of code wraps and a wide table's columns narrow,
because a region that scrolls on its own inside a transcript takes the drag meant for the
transcript. A tag is shown as its characters with the parser's HTML mark removed, and a link is
kept only for `http` and `https`. The person's own messages are plain text.

### Stop is a request, and events say what it did

While a submission of the thread owns a running turn, or is folded into one, the composer offers
Stop: `POST /v1/conversations/{id}:cancel` with `scope: "current"`. The answer says only that the
request was taken. What happened arrives as events — the turn's own `turn.canceled`, or a
`control.ack` saying nothing was running — so nothing in the client marks a turn stopped. The
button reads "Stopping…" until the turn ends or an acknowledgement arrives, whichever is first.

A stop is a submission of its own on the server. It carries no words, the agent closes it as
`dropped` once it has acted, and nothing else ever names it. So a `submission.accepted
{ dropped }` for a submission nothing has been seen of is a stop's own receipt, and gets no row:
drawing one would put a button press into the transcript as a message whose text is unavailable.
A message that really was dropped has its `submission.text` at a lower seq, so its row is
already there. An acknowledgement with `hadRunningTask: false` is the whole story — no terminal
follows it — and is said as one line.

### An image goes up before the message that names it

Reserve, upload, then submit: three steps, each of which can fail without costing the words.

- **Converted on the phone.** The server takes JPEG, PNG, GIF and WebP and refuses everything
  else at reservation, HEIC included, which is what the camera writes. Every picked image is
  re-encoded as JPEG, its long side at most 2048 pixels (`ImagePreparation`).
- **Two credentials, kept apart.** The reservation is made with the sign-in and answers with a
  single-use upload token; the upload carries that token and no sign-in. The token is used once
  and stored nowhere. The reservation also names an upload address, which this client ignores:
  the address is built from the attachment's identifier, so the bytes and the token go to the
  server this phone is signed in to whatever that answer said.
- **A failed upload sends nothing.** The words and the images stay in the composer, and the next
  send does not upload again what already went up.
- **A server without images says so by not having the routes.** A bare `404` on reservation is
  that; the picker is withdrawn and the composer says why. A `404` the server names is about the
  conversation, and is a refusal.

Sent images come back as descriptors on `submission.text` and are read from
`GET /v1/attachments/{id}/content` with the phone's own sign-in when a row that shows one comes on
screen, kept in memory only and only the most recent few. An image this phone has just sent is
kept from the upload. An image the server no longer has says so where the picture would be.

### The chat list says who is there and what has moved

Each agent's row shows how the fleet says it is doing, when its thread was last active and a mark
when the thread has moved on since this phone last showed it. The last two come from
`GET /v1/conversations`; "moved on" compares the thread's newest position with the furthest one
this phone has shown, which is a number per agent in the app's preferences and nothing else. It
claims only that there is something to look at — the newest event may be a reply, a message sent
from the dashboard or progress on a running turn — never what, and never how many.

## One sign-in

The dashboard's address carries both servers: its proxy sends `/api/` and `/ws` to the
orchestrator and `/v1/` to the chat service. The orchestrator owns sign-in, and the chat service
asks it who a caller is, so one access token is good for both.

```
setup code (QR) ── POST /api/auth/devices ──▶ { deviceId, deviceSecret }  stored
                   POST /api/auth/token   ──▶ { accessToken, 15 min }     memory only
every request ───── Authorization: Bearer <accessToken>   (+ the proxy's service token)
```

### What a shortcut may do

Two App Intents: "What needs me" reads how many runs are waiting and which agents are down, and
"Ask an agent" sends one message into an agent's thread. Both go through `QuickActions`, which
signs in the way the app does — the stored credential, one token minted from it, sent in a
header — and keeps nothing afterwards. It never deletes the credential: a refused mint is
reported as signed out, and ending the sign-in stays with `AccessTokenHolder` the next time the
app runs. A send is one attempt; one that does not complete is said to be not known to have been
sent and is not tried again under new identifiers.

No intent answers a gate, starts a workflow or acts on an agent. A shortcut can run from a lock
screen or a watch, and a decision is sent from a screen that shows what is being decided.

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

A code can also be pasted as text, through the system's paste button, for a phone that cannot
point its camera at one. It goes through the same `SetupCode.parse` and the same separate tap.

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
and have nothing else to report to.

A tapped notification carries a `kind` and the identity of what it is about, and
`PushDestination` reads only that: a run's namespace, workflow and run identifiers, a signal
name, an agent's name. The push supplies no question, context, answer or message text, and never
permission to send. Each kind opens the thing it names — a gate, a run, an agent, a thread — but
only when a fresh read still finds it:

| Kind | Opens | When it cannot |
|---|---|---|
| `gate` | that run's gate, for that signal | Fleet |
| `run` | that run, in progress or closed | Runs |
| `agent` | that agent | Fleet |
| `chat` | that agent's thread | Chat |
| anything else, or an identity in part | — | the tab its kind belongs to; Fleet for an unknown kind |

A run is matched by all three identifiers and a gate by the signal as well, so a newer run under
the same workflow identifier, or the same run moved on to another gate, is not what the
notification was about and is not opened in its place. A later navigation or a different sign-in
invalidates an older lookup; changing the control-plane session clears every tab's path. The same
requests are how one tab links into another — an agent's screen opening its thread, a thread
opening its agent — so there is one way a screen is reached by name.

How many runs are waiting is shown on the Fleet tab and on the app's icon. The icon's count is
set by the app from its own reads; the server's notifications carry none, so it is as fresh as
the app's last read and is cleared at sign-out.

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

### What led to a gate is read from that run, and decides nothing

Under the decision the gate screen shows the newest entries of the run's history that say
something: what an agent produced, what failed, what was signalled (`GateActivityDigest`). The
history is read with the gate's own run identifier, never as "the latest run of this workflow",
because what sits beside a decision must be about the run the decision is sent to. It sits
*under* the decision so the answer stays where a thumb expects it. A history that cannot be read
is said in one line and the decision is still offered: it never depended on it.

A run that names its repository as `owner/name` links to its pull request, else its issue, on
GitHub (`RunLinks`). Both halves are held to the characters a repository name may contain, so a
value that is not one cannot become a path to somewhere else on the site.

### Confirm it's you is this phone's guard, not the server's

`OwnerConfirmation` is an optional switch, off by default. With it on, sending a decision, a
disruptive agent action, a schedule action, and cancelling or terminating a run each ask the
phone to confirm its owner first — Face ID or Touch ID, falling back to the passcode. Views ask
through an environment value (`\.confirmOwner`) whose default says yes, so a view rendered alone
behaves as it does with the switch off. Turning the switch off takes the same check, or it would
guard nothing. It is a guard on the interface: the orchestrator neither knows nor cares, and a
credential stolen from the Keychain is not slowed by it.

### An action is "requested", and the state is the evidence

Restart, stop, start and cancel-task answer when the orchestrator has taken the request, not when
the agent has changed. The model records `requested`, reads the fleet again straight away, and
the agent detail screen renders the agent's **current** state from the model rather than the row
that was tapped — so what a person sees after a restart is the agent coming up, not a message
claiming it did.

Which actions are offered follows the agent's state (`AgentAction.available(for:)`). An agent
with no heartbeat is offered restart rather than start: "no heartbeat" may mean hung or stopped,
and a restart is right for both.

Reprovisioning is offered wherever there is a container to recreate. It can outlast the request
that asked for it; that is reported as an outcome not known, and the agent's state says the rest.

### A cancel names the run

`cancelRun` sends the run identifier as well as the workflow identifier. A workflow restarted
under the same name is a different run, and a screen still showing the old one must not cancel
the new one.

Terminating names the run the same way. It is a separate action under cancel, with its own two
taps: a cancel asks the workflow to wind down, and a terminate does not ask. Running a closed run
again starts a new run from that run's own type and input, read by the orchestrator from its
history; `terminateExisting` is never sent, so starting a run never ends one.

### Schedules and memory are read, and schedules are nudged

A schedule can be paused, resumed, or made to start a run now. After any of them the list is
read again, because whether a schedule is paused is the orchestrator's to say. Creating and
editing one stays on the dashboard: it needs a cron expression and a workflow input.

Memory search is read-only, and is sent on return rather than on every keystroke: each search is
an embedding lookup on the server. An answer to an earlier search changes nothing once a newer
one has been asked.

Closed runs are read for the last day by default and for three days when asked, which is as far
back as the orchestrator reads; a window it would silently cap is not offered. The agent and run
lists are narrowed on the phone, from what was already read (`ListSearch`).

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
