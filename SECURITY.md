# Security policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately through GitHub's
[private vulnerability reporting](https://docs.github.com/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
on this repository, rather than opening a public issue.

Include what you observed, how to reproduce it, and the commit you observed it on. Please allow time
for a fix before any public disclosure.

## What is, and is not, in this repository

**This repository contains no deployment credentials.** There is no APNs key, signing certificate,
provisioning profile, App Store Connect credential, keychain password, team identifier, server
hostname, or deployment address in any tracked file, at any commit on the default branch.

All such material is operator-owned and supplied to the release workflow at run time as GitHub
secrets or repository variables. The list of inputs is in
[docs/signing-and-release.md](docs/signing-and-release.md); the values are not in this repository and
must never be.

Pull-request CI is designed so that it **cannot** depend on any of it: `.github/workflows/ci.yml`
references no secret at all and builds with `CODE_SIGNING_ALLOWED=NO`, so it passes on a fork pull
request where secrets are unavailable by design.

`scripts/check-no-private-values.sh` runs on every pull request and fails the build if
secret-shaped content, signing-material file extensions, or absolute addresses appear in a tracked
file. Its patterns are generic by policy — it holds no list of real values to look for.

## Application security posture in this slice

The app currently performs **no networking, no authentication, no token storage, no Keychain access,
and no push registration**, and persists no conversation content. The `aps-environment` entitlement is
a static declaration only. The app ships with no server address; it connects only to a profile the
user supplies.
