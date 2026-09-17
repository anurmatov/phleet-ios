# Development

## What you need

macOS with the pinned Xcode installed. Nothing else — there are no Swift package dependencies
to resolve, and `scripts/bootstrap.sh` fetches the one build tool it needs.

The shell gates (`make lint`, `make selftest`) run on Linux too, and need only `bash` and
`python3`. That is deliberate: it means the checks that guard this repository can be exercised
by someone who does not have a Mac.

## The pins

Every one of these is an explicit value, not a floating reference, and every one fails the job
rather than falling back.

| Pin | Value | Where it lives |
|---|---|---|
| Runner image | `macos-26` | `.github/workflows/ci.yml`, `.github/workflows/release.yml` |
| Xcode | `/Applications/Xcode_26.6.app` | `scripts/bootstrap.sh` (`PINNED_XCODE_APP`) |
| XcodeGen | `2.46.0`, sha256 `4d9e34b6…` | `.xcodegen.lock` |
| Deployment target | iOS 17.0 | `Config/Base.xcconfig`, `project.yml` |
| Simulator | chosen by a total rule, never by name | `scripts/select-simulator.sh` |

### Why these values

**`macos-26` with its default Xcode 26.6.** The image ships only Xcode 26.x, and therefore only
iOS 26.x simulator runtimes — every runtime on it is above the iOS 17.0 floor and is supported
by the selected Xcode. That property is what makes the simulator pick rule safe: "highest
runtime" cannot select a runtime the pinned Xcode is too old to build against. An image carrying
two Xcode generations (for example `macos-15`, which has both 16.x and 26.x) does not have that
property, because `simctl` reports runtimes from every installed Xcode and the highest one may
not be usable by the one you selected.

**XcodeGen 2.46.0, pinned by artifact hash.** A version string alone does not guarantee that two
machines generate the same project; the hash does. 2.46.0 also recognises String Catalogs
(`.xcstrings`) as resources — an older release drops `Localizable.xcstrings` from the bundle,
after which every `a11y.*` lookup returns its own key and `AccessibilityStringTests` fails with
no obvious cause.

### Moving a pin

The runner image label will eventually be retired, and the job will fail rather than silently
move. When that happens:

1. Read the current [runner image manifest](https://github.com/actions/runner-images/tree/main/images/macos)
   and pick the newest image whose default Xcode supports an iOS 17.0 deployment target.
2. Confirm every installed iOS **simulator** runtime on that image is at or above 17.0, or that
   the highest one is supported by the Xcode you are pinning.
3. Update `runs-on` in both workflows and `PINNED_XCODE_APP` in `scripts/bootstrap.sh` together.
4. Record the new values and the reason in the table above.

## How each pin fails closed

| Situation | What happens |
|---|---|
| Pinned Xcode absent | `bootstrap.sh` exits 1 and prints `ls -d /Applications/Xcode*.app`. It never falls back to the runner default |
| XcodeGen download fails | Three attempts (one plus two retries), then exit 1 naming the tag and URL |
| XcodeGen hash mismatch | Exit 1 printing expected and actual. No Homebrew or `PATH` fallback exists |
| No iOS ≥ 17.0 simulator | `select-simulator.sh` exits 1 listing every runtime `simctl` reported |
| Malformed `simctl` JSON | Exit 1 with a parse message. It never prints a partial or empty destination |
| Runner label retired | The workflow fails. There is no `macos-latest` fallback |
| Release input missing | `check-release-inputs.sh` names every missing input and stops before anything is created |

## Commands

```
./scripts/bootstrap.sh   # verify Xcode, fetch and hash-verify XcodeGen into .tools/
make generate            # project.yml -> Phleet.xcodeproj  (git-ignored)
make lint                # tracked-file invariant scan
make selftest            # run every gating script against its fixtures
make test                # build and test on the selected simulator
make clean               # remove build/, the generated project, DerivedData
```

`make test` passes `CURRENT_PROJECT_VERSION=${GITHUB_RUN_NUMBER:-1}`, which is how the build
number reaches the app without an `.xcconfig` being able to express it.

## Working here without knowing Xcode

Three things account for most of it:

1. **The project is `project.yml`.** `Phleet.xcodeproj` is output. If you change a target,
   a build setting, or add a file outside an existing source directory, you change the YAML and
   run `make generate`. Never hand-edit a `.pbxproj`; it is marked generated in `.gitattributes`
   and `make lint` fails if one becomes tracked.
2. **Build settings live in `Config/Base.xcconfig`**, applied to every configuration, with
   per-target overrides in `project.yml`. Your own signing values go in
   `Config/Signing.local.xcconfig`, which is git-ignored and pulled in by an optional
   `#include?` — the `?` matters, because the file is absent on every clean checkout.
3. **The simulator is chosen for you.** Do not pass `-destination` by device name;
   `scripts/select-simulator.sh` prints a UDID-based destination by a documented total rule so
   two runs on the same machine build for the same thing.

## Testing the scripts without macOS

Every gating script takes injected input, so none of them needs the real environment:

```
./scripts/select-simulator.sh --self-test              # against tests/fixtures/simctl/
./scripts/select-simulator.sh --simctl-json FILE       # one-shot against your own document
./scripts/check-no-private-values.sh --self-test       # against tests/fixtures/scanner/
./scripts/check-release-inputs.sh --self-test          # runs itself under env -i
```

Each self-test asserts both directions — the passing case and the case that must fail. A check
that can only go green is not a check, and `make selftest` runs before the gates themselves in
CI so a gate that has stopped being able to fail is caught rather than trusted.

## Two details that look like mistakes and are not

- **The `.plist` files carry no `DOCTYPE`.** The conventional Apple DOCTYPE line embeds an
  `http://www.apple.com` URL, which the group 2 address check correctly rejects inside
  `Phleet/**`. The declaration is optional and nothing needs it, so it is omitted rather than
  widening the allowlist.
- **`scripts/**` is outside the group 2 address scan.** `bootstrap.sh` legitimately contains the
  XcodeGen download URL. Do not "fix" the scope; the download is pinned by tag and hash instead.
