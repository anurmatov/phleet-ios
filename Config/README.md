# Config

| File | Tracked | Purpose |
|---|---|---|
| `Base.xcconfig` | yes | Deployment target, Swift version, product name, versioning, warnings-as-errors |
| `Signing.example.xcconfig` | yes | Placeholder template. Contains no real identifiers |
| `Signing.local.xcconfig` | **no — git-ignored** | Operator-created, holds your real team identifier and profile |

## Signing.local.xcconfig is yours, and stays out of git

`Config/*.local.xcconfig` is listed in `.gitignore`, and `scripts/check-no-private-values.sh`
fails the build if such a file ever becomes tracked. A team identifier is an operator-owned value; it
does not belong in a public repository.

To set up a local signed build:

```
cp Config/Signing.example.xcconfig Config/Signing.local.xcconfig
$EDITOR Config/Signing.local.xcconfig
make generate
```

`Base.xcconfig` ends with `#include? "Signing.local.xcconfig"`. The `?` is load-bearing: the file is
absent on every clean checkout and on CI, and a plain `#include` would fail project generation there.
With the optional form, an absent file simply contributes nothing.

CI never needs this file. Pull-request CI builds for the simulator with the **ad-hoc** identity
(`CODE_SIGN_IDENTITY=-`) and references no signing material at all: ad-hoc needs no certificate, no
keychain item and no provisioning profile. It is used rather than disabling signing outright
because an app with no embedded entitlements has no keychain access group on the simulator, and the
tests covering the device credential cannot run at all.
