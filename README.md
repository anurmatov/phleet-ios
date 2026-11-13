# Phleet

**Phleet** is the native iOS client for the public [phleet](https://github.com/anurmatov/phleet)
platform. It connects to a **Fleet server that you supply when you sign in**. No server
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

## Status — one sign-in, a fleet view, and chat with any agent

The app has three tabs over one sign-in. **Fleet** and **Runs** use the orchestrator's operator
API: what is waiting for you, how every agent is doing, and workflow runs in progress and
recently closed. **Chat** lists the agents that have chat turned on and keeps one thread with
each. All three reach the server through one address — the one you open the dashboard at — with
one credential.

What signing in does:

- **one step** — the dashboard shows a QR code under Credentials → Devices → Connect a phone.
  Scanning it shows the address it names and connects to nothing; a second tap registers this
  phone with the code's one-time enrollment code. The credential is stored before the first
  token is minted, and presenting the same code again overwrites a rotated secret
- **one credential** — one Keychain item, `AfterFirstUnlockThisDeviceOnly`, holding the address,
  the access proxy's service token when there is one, and this phone's device id and secret. The
  fifteen-minute access token is minted from it when needed and held in memory only; every
  request carries it in a header, never in a URL
- **sign out** — from the connection sheet: the orchestrator is told to forget this phone for
  notifications and to revoke it, then the credential is deleted. A phone revoked from the
  dashboard returns to setup and says why
- **older codes and older installs** — a code from a dashboard that predates one sign-in (it
  carried the operator token) is refused by name. The Keychain items an earlier build kept,
  including that operator token, are deleted at launch; whether notifications were on carries
  over to the first sign-in to the same address

What Fleet does:

- **needs you** — the workflow runs waiting at a gate, oldest first, with the decisions the
  orchestrator registers for that gate; a decision takes two taps and is sent with the run and
  gate reference that were on screen, so a stale screen is refused rather than obeyed
- **human input** — the existing gate screen loads the original Question, Context and requester
  from exact namespace/workflow/run history, literally and in full; choose one ordered option,
  enter multiline text, or choose the approve/reject preset, then confirm separately
- **answer safety** — Value and optional Comment are preserved unchanged (2000 UTF-16 units each);
  input is data only, never authority to execute work; missing/invalid history, loading and stale
  requests cannot send, and an uncertain send refreshes the same run without replay
- **agents** — every agent, the ones that are down or late first, with its current task
- **agent actions** — restart, stop, start, or cancel the task in hand; which are offered follows
  the agent's state, each takes two taps, and the agent's own state afterwards is the evidence
- **logs** — the tail of an agent's container log, followed while the screen is open
- **runs** — in progress, stopped without finishing, and finished in the last day; a run's
  history; cancel, addressed to that run rather than to its workflow name
- **start a workflow** — pick a type and fill in its text, number and switch inputs
- **notifications** — turned on from the connection sheet; the orchestrator then tells this phone
  when a gate is waiting, a workflow failed or an agent went down, and tapping one opens the tab
  that shows it. Every reason they are not on is said in words
- **freshness** — HTTPS reads on a timer are the source of truth; the orchestrator's live socket
  only makes changes arrive sooner, so a socket that cannot pass a proxy costs nothing but speed
- **no redirects** — a request is never followed to another host, so a proxy's sign-in redirect
  is reported as "not let in" instead of handing the service token to the next address

What Chat does:

- **agents** — the agents with chat turned on, read from the orchestrator each time the list
  appears; a server without the chat service says so instead of showing an empty list
- **a thread per agent** — opened as `main` with that agent, which is the same conversation the
  dashboard opens for the same person; stream attached first, then catch-up, with the live frames
  buffered in between; paging, history-gap separators, cursor advance, and every one of the eight
  close codes handled distinctly
- **your own messages, read back** — what you said comes back from the server with the rest of
  the thread, so another phone or a relaunch shows each message once, exactly as typed, above its
  reply. A message the server no longer has — older than it retains, or from before it kept them
  — says its text is unavailable rather than leaving a reply with no question. Needs a chat
  service that stores `submission.text`, as public phleet does from
  [`cb6153f`](https://github.com/anurmatov/phleet/blob/cb6153f2cac04521916ce61706f8a7641b3c6443/docs/conversation-protocol.md#submissiontext--the-users-own-messages-are-part-of-the-log-305);
  nothing earlier is backfilled
- **chat turned off** — an agent whose chat was turned off says so, names where it is turned back
  on, and offers to try again
- **Markdown** — an agent's reply renders emphasis, code spans, fenced code blocks and web links;
  everything else stays as the characters the agent wrote, nothing is read as HTML, and a link
  that is not `http` or `https` opens nothing. Your own messages stay plain text
- **drafts** — what you typed to one agent stays with that agent, and survives signing out
- **reply notifications** — when notifications are on, the orchestrator tells this phone when an
  agent replies while no client is watching that thread; tapping one opens the Chat tab

What it still does not do:

- **no setup without a camera** — the dashboard shows the setup code only as a QR code, so a
  phone that cannot scan cannot be set up
- **no provisioning** — an agent that was never provisioned, or needs reprovisioning, is handled
  from the web dashboard
- **no terminate or restart of a run** — a run can be cancelled, which asks it to stop; forcing
  one to stop and restarting one are not offered
- **no rich workflow inputs** — a workflow that needs a list or a nested value is started from
  the dashboard
- **no editing** — instructions, project contexts, workflow definitions, credentials and secret
  bindings stay on the web dashboard; chat is turned on per agent there too
- **limited notification destinations** — a human-input tap with complete run identity refreshes
  Fleet and opens only the matching pending request; missing or stale identities stay on the list,
  and other notifications still open the Fleet, Runs or Chat tab, not the particular gate, run or
  thread
- **human-input compatibility** — requires the shipped human-input backend contract and exact-run
  history support; older or unknown request formats remain unavailable rather than guessed
- **no voice, attachments, approvals, or multi-agent rooms**
- **no steer or cancel interface** — the routes exist; this app does not surface them
- **no local persistence of conversation history** — the transcript is in memory only; history
  is read back from the server, never from the phone

Every test is hermetic: nothing in the suite opens a socket, and it passes with the runner
offline. Nothing here has been exercised against a live server yet — including the sign-in, the
chat agent list and an access proxy: the fixtures are written from the server's source, not
captured from a running one, and whether its sockets (live state, agent logs, chat) pass a proxy
with service-token headers is untested. The camera scanner cannot run on a simulator, so CI covers
reading a setup code and what it may do, not the camera itself. Notifications are covered the
same way: the app's own steps run against a stand-in for the system, and no test asks Apple for a
device token or receives a real notification.

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
| `PhleetUITests/` | launch, fleet and conversation smoke tests, driven by an in-app scripted backend |
| `Config/` | `.xcconfig` build settings; local signing overrides are git-ignored |
| `scripts/` | build-gate scripts, each with a `--self-test` mode, plus the app-icon generator |
| `tests/fixtures/` | synthetic inputs for the script self-tests, recorded protocol event sequences, and orchestrator responses |
| `docs/` | toolchain, signing/release, and architecture notes |

## Documentation

- [docs/development.md](docs/development.md) — pinned toolchain and how to build without Xcode knowledge
- [docs/architecture.md](docs/architecture.md) — the layers, the transport seam, the cursor rules, and the sign-out rule
- [docs/signing-and-release.md](docs/signing-and-release.md) — operator-owned signing and the TestFlight path
- [CONTRIBUTING.md](CONTRIBUTING.md) — how to work on this, and what must never be committed
- [SECURITY.md](SECURITY.md) — how to report a vulnerability

## License

[MIT](LICENSE). Copyright (c) 2026 Anvar Nurmatov.
