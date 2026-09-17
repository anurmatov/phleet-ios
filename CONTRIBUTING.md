# Contributing

## What must never be committed

This is a public repository. The following are hard rules, enforced on every pull request by
`scripts/check-no-private-values.sh`:

1. **No signing or push material.** No `.p8`, `.p12`, `.cer`, `.certSigningRequest`,
   `.mobileprovision`, `.pem`, or `.key` file. No App Store Connect API key. No generated
   `ExportOptions.plist`. No `DEVELOPMENT_TEAM` value in any tracked file.
2. **No absolute addresses.** No server hostname, IP address, port, or deployment URL in sources,
   `project.yml`, `Info.plist`, `.xcconfig` files, workflows, or fixtures. Synthetic values use the
   reserved `.invalid` domain.
3. **No identifiers belonging to people or infrastructure.** No team identifier, user identifier,
   device token, account name, or internal topology detail.
4. **No generated Xcode project.** `Phleet.xcodeproj` is produced by `make generate`; committing it
   lets it drift from `project.yml` silently.
5. **No scan denylist of real values.** Every pattern in `check-no-private-values.sh` is generic. A
   list of real hostnames to search for, published in a public repository, is itself the leak.

If you need a value that looks like an address in a test, use `example.invalid`.

## Working on this

```
./scripts/bootstrap.sh
make generate lint selftest test
```

`make lint` and `make selftest` run on Linux as well as macOS and need no Xcode, so the shell gates
can be exercised anywhere. `make generate` and `make test` need macOS with the pinned Xcode.

### The project is text

`project.yml` is the source of truth for the Xcode project. A `.pbxproj` is a machine-generated blob
that cannot be reviewed in a diff and cannot be safely hand-edited. Change `project.yml`, run
`make generate`, and commit only the YAML.

### Every gate must be able to fail

A check that cannot go red is worse than no check, because it teaches everyone to trust it. When you
add a script gate or an acceptance test, add the negative case in the same change and prove it fails:
that is what the `--self-test` modes and `tests/fixtures/` exist for.

### Accessibility is acceptance, not polish

Use semantic font styles only — no fixed point sizes, no `minimumScaleFactor`, no fixed-height
container around text. Every control carries an identifier and a label drawn from
`AccessibilityIdentifier`. Never make colour the only signal for a state.

## Pull requests

Fill in `.github/pull_request_template.md` honestly. In particular, do not tick device, signing,
TestFlight, or VoiceOver verification: CI cannot establish any of them, and reporting them as passing
from a CI run is a false claim. Those are operator gates.
