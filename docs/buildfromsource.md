# Build from source

You need macOS 14 or later and the Command Line Tools (`xcode-select --install`). Xcode isn't needed.

```sh
./build.sh             # build build/jaredsmacutils.app
./build.sh --install   # build, copy to /Applications and open
./build.sh --pkg       # build the installer, downloads/jaredsmacutils.pkg, for Apple silicon and Intel
swift test             # run the unit tests
```

The installer copies the app into `/Applications`, removes `Yafie.app` from before the rename, hands the app to the person installing (so **Check for Updates…** can replace it later), then opens it. Its scripts and closing page are in `Resources/pkg`.

The app was called Yafie before 1.1.4, and it still is inside: the Swift package, the bundle ID `io.github.jfreema.yafie` and `/etc/sudoers.d/yafie`. Keep them. Users' permissions, settings and password-free setup depend on them. Its names, Jared's Cool Mac Utilities App and Jared's Mac App for short, are in `Resources/Info.plist`, `Resources/en.lproj/InfoPlist.strings` and `Yafie.name` in the code.

## Signing

From 1.1.6, releases are signed with Jared's **Developer ID** certificates (team `885XHF7XLL`) and notarized by Apple, so the installer opens on any Mac without a Gatekeeper warning. This doesn't involve the App Store. macOS ties the app's permissions (Accessibility for window snapping and app previews, Screen Recording for snips and window pictures, Microphone for the tuner) to the team, so they last across updates and certificate renewals. Releases before 1.1.6 used a self-signed certificate, so updating to 1.1.6 asks everyone for the permissions once more.

Two certificates do it: **Developer ID Application** signs the app, with the hardened runtime and `Resources/jaredsmacutils.entitlements` (the microphone), and **Developer ID Installer** signs the installer. `build.sh` uses the first of each in the keychain, or `YAFIE_SIGNING_IDENTITY` and `YAFIE_INSTALLER_IDENTITY`. Without them, `./build.sh` and `./build.sh --install` sign ad hoc, and `./build.sh --pkg` stops. With `NOTARY_APPLE_ID` and `NOTARY_PASSWORD` set, `--pkg` also notarizes the installer, with the app in it, and staples the ticket.

- **First time:** on your Mac, run `zsh scripts/setup-signing.sh`. It makes the private keys and two signing requests, opens Apple's site for you to turn each into a certificate (pick **G2 Sub-CA**), packages them as .p12 files with a random password, asks for an app-specific password from [account.apple.com](https://account.apple.com) and checks it with Apple, then adds the secrets below to the repo. With the GitHub CLI (`brew install gh`, then `gh auth login`) it adds them itself; without it, it opens GitHub's page and puts each one on your clipboard. Your login keychain keeps the certificates as the backup.
- **For GitHub:** the Release workflow signs and notarizes with five repository secrets:

  | Secret | Value |
  |---|---|
  | `DEVELOPER_ID_APP_P12` | The Developer ID Application .p12, base64 |
  | `DEVELOPER_ID_INSTALLER_P12` | The Developer ID Installer .p12, base64 |
  | `DEVELOPER_ID_P12_PASSWORD` | The password of both .p12 files |
  | `NOTARY_APPLE_ID` | The Apple ID email |
  | `NOTARY_PASSWORD` | The app-specific password |

- **The team is checked.** The workflow refuses a release not signed by `TEAM_ID` in `.github/workflows/release.yml`, and **Check for Updates…** refuses an update signed by another team than the running copy. Never change the team: everyone would have to allow the app again, and Check for Updates couldn't take them there.
- **Renewing:** the certificates last five years. Run the setup script again before they expire; certificates from the same team keep everyone's permissions.
- **Apple's wait:** Apple usually notarizes in minutes, but can take hours. Test runs wait 15 minutes, then carry on unnotarized with a warning. A release waits an hour, then stops without publishing, so re-run it once Apple has finished.

## Release an update

1. Raise `CFBundleShortVersionString` in `Resources/Info.plist`. **Check for Updates…** only offers a higher version.
2. Commit and push. The Release workflow (`.github/workflows/release.yml`) does the rest on GitHub's Macs:
   - runs the tests
   - builds the installer with `./build.sh --pkg`, signs it and has Apple notarize it
   - checks it the way **Check for Updates…** will
   - commits the installer, `downloads/jaredsmacutils.pkg`, its update feed, `downloads/update.json`, and the README's version line to `main`

   Follow it under the repo's **Actions** tab. After it finishes, GitHub can take up to 5 minutes to serve the new files.

**Check for Updates…** reads `downloads/update.json` and finds the app in the installer by its bundle ID, so a new version can have a new name. It goes in beside the old copy, which is then removed. Copies before 1.1.3 read `downloads/latest.json` instead, and only take an app named `Yafie.app`. So `latest.json` and `Yafie.pkg` stay at 1.1.3, the last release named Yafie, for good: old copies update to it first, then on to the new name. `build.sh` leaves them alone, and the workflow checks that they don't change.

To try a build without publishing, choose **Actions → Release → Run workflow**, leaving **Publish** off. The installer is attached to the run.

Building the release yourself still works: run `./build.sh --pkg`, then commit and push `downloads/` along with the version. The workflow sees that the version is already published, so it only checks the build.

## Icon and artwork

Two masters drive the artwork: `Resources/AppIcon.png`, the app icon at 1024 × 1024 pixels on Apple's macOS icon grid, and `Resources/MenuIcon.png`, the menu bar's glyph, black on a clear background. `Resources/draw-icon.swift` draws both, a J in sunglasses, from the same shapes. The menu bar draws only the glyph's shape, not its colors, so parts that overlap, like the sunglasses on the J, need a clear gap around them. After changing the drawing, run:

```sh
./Resources/draw-icon.swift
./Resources/make-icon.swift
```

This rebuilds `Resources/AppIcon.icns`, the menu bar icons (`Resources/MenuIcon.tiff`, and the outlined `MenuIconOutline.tiff` it draws from the same glyph), `docs/icon.png` and `docs/social-preview.png`. GitHub takes the social preview by hand, under the repo's **Settings → Social preview**.
