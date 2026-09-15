# Releasing Simpilot

Simpilot ships **Developer ID–signed and notarized, outside the App Store**.
That is not a preference. A sandboxed process can spawn neither `xcrun` nor read
`~/Library/Developer/CoreSimulator`, so an App Store build would launch and show
an empty inventory with no visible error. The App Sandbox must stay off, and
`scripts/release.sh` aborts if it is ever switched on.

```
./scripts/release.sh                 build and sign locally, change nothing else
./scripts/release.sh --notarize      also submit to Apple, staple, and package
./scripts/release.sh --version 1.0.0 set the marketing version first
```

Notarization uploads the app to Apple, so it is opt-in rather than the default.

## Configuration

Two untracked files hold everything account-specific, so a fork builds without
editing anything the repository tracks:

| File | Copy from | Holds |
|---|---|---|
| `scripts/release.env` | `release.env.example` | `TEAM_ID`, `GITHUB_REPO` |
| `Simpilot/Config/Local.xcconfig` | `Local.xcconfig.example` | `DEVELOPMENT_TEAM` |

Neither contains a secret. The Team ID is embedded in every Developer ID
signature and readable from any released build with `codesign -dv`, and the
repository name is public by definition. They are kept out of the repository so
the project is not tied to one developer's account, not because they are
sensitive.

The credentials that *are* sensitive — your Apple ID and its app-specific
password — never touch the repository. They live in the keychain, placed there by
`notarytool store-credentials`.

`release.sh` stops with an explanation if either file is missing.

## One-time setup

Both steps need a **paid Apple Developer Program membership**. The free tier
issues only "Apple Development" certificates, which cannot sign for distribution
outside the App Store.

### 1. Developer ID Application certificate

Under automatic signing, Xcode usually obtains this itself during export, so it
may already be handled — the certificate can be absent from the keychain right
up until the first export installs it. That is why the script warns about a
missing certificate rather than refusing to run: a hard check would block the
very step that obtains one.

If export fails with a signing error, create the certificate explicitly in
Xcode → Settings → Accounts → select the team → Manage Certificates → **+** →
**Developer ID Application**, or at
[developer.apple.com](https://developer.apple.com/account/resources/certificates).
This requires a paid Apple Developer Program membership; the free tier issues
only "Apple Development" certificates, which cannot sign for distribution
outside the App Store.

Check what is present:

```
security find-identity -v -p codesigning | grep "Developer ID Application"
```

### 2. Notarization credentials

Create an app-specific password at [appleid.apple.com](https://appleid.apple.com)
— not your Apple ID password — then store it in the keychain:

```
xcrun notarytool store-credentials "simpilot" \
    --apple-id "<your-apple-id>" \
    --team-id "<your-team-id>" \
    --password "<app-specific-password>"
```

The profile name must match `NOTARY_PROFILE` in the script, which defaults to
`simpilot`.

## What the script does

1. Verifies the certificate and, for `--notarize`, the credential profile — and
   stops with an explanation rather than a cryptic signing error if either is
   missing.
2. Runs `swift test`. A failing suite stops the release.
3. Archives in Release configuration and exports with the Developer ID method.
4. Verifies the signature, confirms the hardened runtime, and **aborts if the
   App Sandbox is present**.
5. With `--notarize`: zips and submits the app, waits, staples the ticket,
   builds a DMG containing the stapled app, signs and notarizes the DMG, and
   staples that too.
6. Runs `spctl --assess` — what another Mac actually decides on open.

Output lands in `build/`, which is not tracked.

## Verifying a release properly

Gatekeeper treats a locally built app differently from a downloaded one, so a
check on the build machine proves little. Test on a Mac that has never run
Simpilot, or clear the quarantine state:

```
xattr -d com.apple.quarantine ~/Downloads/Simpilot-1.0.0.dmg   # to undo a test
spctl --assess --type execute --verbose=4 /Applications/Simpilot.app
```

A correct result reads `accepted` and `source=Notarized Developer ID`.

## Updates

Sparkle 2 checks the appcast at
the URL in `SUFeedURL`, which points at the repository's default branch.
Automatic checking is **off** by default, so Sparkle asks on first launch rather
than contacting a server unprompted — the consistent choice for an app that
refuses to delete a simulator without confirmation.

`release.sh` regenerates and signs `appcast.xml` on every run. Publishing is
deliberately two manual steps, in this order:

1. **Create the GitHub release first** and attach the DMG. The tag must match the
   marketing version exactly (`v0.2` for 0.2) because the appcast's enclosure URL
   points at that tag.
2. **Then** commit and push `appcast.xml`. Pushing it first advertises a download
   that returns 404 to everyone who checks in the meantime.

### The signing key

Every update is signed with an EdDSA private key held in the login keychain as
*"Private key for Sparkle EdDSA signing"*. Its public half is baked into every
released app.

**Back it up.** If the key is lost, existing installations can never be updated
again: a new key means a new public key, and copies already in the wild will
reject anything signed with it. There is no recovery path — only shipping a fresh
download and asking people to replace the app by hand.

```
# export (prompts for the keychain), then store somewhere safe and offline
security find-generic-password -s "https://sparkle-project.org" -w
```

### Build numbers matter more than version strings

Sparkle compares `sparkle:version`, which comes from `CURRENT_PROJECT_VERSION`,
not from the marketing version. `release.sh` increments it on every run. A release
that leaves it unchanged is invisible: the update is built, signed, notarized,
served — and never offered.

### The keychain prompt

The first release built on a machine stops with a macOS dialog asking permission
for `codesign` to use the Developer ID key. It is easy to mistake for a hang,
because `xcodebuild` simply sits there. Choose **Always Allow**; plain "Allow"
makes it reappear for each of Sparkle's nested XPC services and again next time.

## Known gaps

- **Release creation is manual.** Attaching the DMG to a GitHub release is a web
  UI step; `gh` is not installed. With it, `release.sh` could do the whole thing.
- **No update has ever been installed.** The feed, signature and download path are
  each verified, but nothing has yet upgraded itself from one version to the next.
  That only becomes testable once two releases exist.
