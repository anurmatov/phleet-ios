## What this changes

<!-- One paragraph. What behaviour is different after this merges? -->

## Why

<!-- Link the issue. What problem does this solve? -->

## How it was verified

<!-- Name what you actually ran and what it printed. "CI is green" is a starting point, not a
     verification: say which check would have gone red if this change were wrong. -->

## Checklist

- [ ] No signing or push material: no `.p8`, `.p12`, `.cer`, `.certSigningRequest`,
      `.mobileprovision`, `.pem`, `.key`, App Store Connect credential, or `ExportOptions.plist`
- [ ] No private hostname, IP address, port, team identifier, user identifier, device token, or
      account name in any tracked file; synthetic values use `example.invalid`
- [ ] No generated `Phleet.xcodeproj` committed, and no hand-edited `.pbxproj`
- [ ] Pull-request CI still passes with zero secrets (it must work on a fork PR)
- [ ] `make lint` and `make selftest` pass
- [ ] Any new gate has a negative case proving it can fail, not only a passing case
- [ ] New user-facing text uses a semantic font style and carries an accessibility label from
      `AccessibilityIdentifier`

## Not claimed here

CI cannot establish any of the following. Leave them unticked unless an operator has actually
done them and says so explicitly:

- [ ] Signed build on a physical Mac
- [ ] TestFlight distribution
- [ ] VoiceOver navigation or Dynamic Type on a physical device
