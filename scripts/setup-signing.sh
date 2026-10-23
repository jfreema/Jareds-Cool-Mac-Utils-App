#!/bin/zsh
# Makes the app's two Developer ID certificates and adds the five secrets the Release workflow signs and notarizes with.
# Run it once on your Mac, in Terminal:  zsh scripts/setup-signing.sh
#
# You sign in to Apple to turn two signing requests into certificates, and to make an app-specific password.
# Everything else happens here. The private keys are made on this Mac and only go to your login keychain and to the
# repo's encrypted secrets. Nothing secret is printed. See docs/buildfromsource.md.
set -euo pipefail

REPO="jfreema/Jareds-Cool-Mac-Utils-App"
# The team in the Release workflow's TEAM_ID. Users' permissions are tied to it.
EXPECTED_TEAM="885XHF7XLL"
# macOS's own OpenSSL, whose .p12 files the keychain reads
OPENSSL=/usr/bin/openssl
WORK="$(mktemp -d)"
TEST_KEYCHAIN="$WORK/test.keychain-db"
USED_CLIPBOARD=0
KINDS=(Application Installer)

cleanup() {
    security delete-keychain "$TEST_KEYCHAIN" 2>/dev/null || true
    rm -rf "$WORK"
    for kind in $KINDS; do rm -f "$HOME/Desktop/JaredsMacApp-$kind.certSigningRequest"; done
    (( USED_CLIPBOARD )) && pbcopy < /dev/null
    return 0
}
trap cleanup EXIT
chmod 700 "$WORK"
touch "$WORK/started"

step() { print; print -P "%B$1%b" }
fail() { print -P "%F{red}$1%f" >&2 }
# Prompts printed by hand, since read only shows its own in an interactive shell
ask() { print -n -- "$2"; read -r "$1" }
ask_hidden() { print -n -- "$2"; read -rs "$1"; print }

print -P "%BJared's Mac App signing setup%b"
print "This makes Developer ID certificates for $REPO and adds its signing secrets. It takes about 10 minutes."

# MARK: GitHub

if command -v gh >/dev/null && gh auth status --hostname github.com >/dev/null 2>&1 \
        && gh secret list --repo "$REPO" >/dev/null 2>&1; then
    USE_GH=1
    print "GitHub CLI is signed in, so the secrets go straight to the repo."
else
    USE_GH=0
    print "GitHub CLI isn't set up here, so at the end you'll paste each secret into GitHub's page. (To skip that, run"
    print "'brew install gh && gh auth login' first, then this again.)"
fi

# MARK: Certificates

step "1. Your Apple ID"
APPLE_ID=""
while [[ -z "$APPLE_ID" ]]; do
    ask APPLE_ID "The email you sign in to your Apple Developer account with: "
done

for kind in $KINDS; do
    $OPENSSL req -new -newkey rsa:2048 -nodes -keyout "$WORK/$kind.key" -subj "/emailAddress=$APPLE_ID/CN=$(id -F)" \
        -out "$HOME/Desktop/JaredsMacApp-$kind.certSigningRequest" 2>/dev/null
    chmod 600 "$WORK/$kind.key"
done

# Waits for the certificate made from $kind's request, and checks it
fetch_certificate() {
    local kind="$1" answer cer newest subject team name
    while true; do
        print
        ask answer "When it's downloaded, press Return. (Or drag the .cer file into this window first.) "
        cer="$(print -r -- "$answer" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        cer="${(Q)cer}"
        if [[ -z "$cer" ]]; then
            newest=(~/Downloads/*.cer(N.om[1]))
            if (( ${#newest} )) && [[ "${newest[1]}" -nt "$WORK/started" ]]; then
                cer="${newest[1]}"
            else
                fail "No new .cer file in Downloads yet."
                continue
            fi
        fi
        if ! $OPENSSL x509 -inform DER -in "$cer" -out "$WORK/$kind.pem" 2>/dev/null \
                && ! $OPENSSL x509 -in "$cer" -out "$WORK/$kind.pem" 2>/dev/null; then
            fail "$cer isn't a certificate."
            continue
        fi
        if [[ "$($OPENSSL x509 -noout -modulus -in "$WORK/$kind.pem")" \
                != "$($OPENSSL rsa -noout -modulus -in "$WORK/$kind.key")" ]]; then
            fail "$cer was made from a different signing request. Upload JaredsMacApp-$kind.certSigningRequest."
            continue
        fi
        subject="$($OPENSSL x509 -noout -subject -in "$WORK/$kind.pem")"
        if [[ "$subject" != *"Developer ID $kind"* ]]; then
            fail "That's not a Developer ID $kind certificate. Make it again and pick Developer ID $kind."
            continue
        fi
        break
    done
    touch "$WORK/started"  # so the next one can't pick up this file
    team="$(print -r -- "$subject" | sed -nE 's/.*OU ?= ?([A-Z0-9]{10}).*/\1/p')"
    name="$(print -r -- "$subject" | sed -nE "s/.*CN ?= ?(Developer ID $kind: [^/,]*).*/\1/p")"
    if [[ -z "$team" || -z "$name" ]]; then
        fail "Couldn't read the team ID from the certificate ($subject)."
        exit 1
    fi
    if [[ "$team" != "$EXPECTED_TEAM" ]]; then
        fail "That certificate is from team $team, but the app's releases are signed by team $EXPECTED_TEAM."
        exit 1
    fi
    print "Got $name"
    NAMES[$kind]="$name"
}

typeset -A NAMES
step "2. Make the certificates on Apple's site"
for kind in $KINDS; do
    print
    print "Opening developer.apple.com for the Developer ID $kind certificate. There:"
    print "  a. Sign in if asked."
    print "  b. Choose 'Developer ID $kind' and click Continue."
    print "  c. Select 'G2 Sub-CA' if it asks. (Apple preselects 'Previous Sub-CA', which expires in 2027.)"
    print "     Click Choose File and pick JaredsMacApp-$kind.certSigningRequest on your Desktop."
    print "  d. Click Continue, then Download."
    open "https://developer.apple.com/account/resources/certificates/add"
    fetch_certificate "$kind"
done

step "3. Package them"
P12_PASSWORD="$($OPENSSL rand -base64 24)"
export P12_PASSWORD
security create-keychain -p "$P12_PASSWORD" "$TEST_KEYCHAIN"
for kind in $KINDS; do
    # Apple's intermediate certificate goes in too, so the signature carries the whole chain wherever it's made
    issuer="$($OPENSSL x509 -noout -issuer -in "$WORK/$kind.pem" | sed 's/^issuer= *//')"
    chain=()
    for ca in DeveloperIDG2CA DeveloperIDCA; do
        if curl -fsSL "https://www.apple.com/certificateauthority/$ca.cer" -o "$WORK/$ca.cer" 2>/dev/null \
                && $OPENSSL x509 -inform DER -in "$WORK/$ca.cer" -out "$WORK/$ca.pem" 2>/dev/null \
                && [[ "$($OPENSSL x509 -noout -subject -in "$WORK/$ca.pem" | sed 's/^subject= *//')" == "$issuer" ]]
        then
            chain=(-certfile "$WORK/$ca.pem")
            break
        fi
    done
    package() {
        $OPENSSL pkcs12 -export -inkey "$WORK/$kind.key" -in "$WORK/$kind.pem" "${chain[@]}" \
            -name "${NAMES[$kind]}" -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -passout env:P12_PASSWORD \
            -out "$WORK/$kind.p12" "$@"
    }
    # The SHA-1 MAC every macOS can read, where this OpenSSL has the option
    package -macalg sha1 2>/dev/null || package
    # Imports it the way the Release workflow will, to be sure it works there
    security import "$WORK/$kind.p12" -k "$TEST_KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
    if ! security find-identity -v "$TEST_KEYCHAIN" | grep -q "Developer ID $kind"; then
        fail "The packaged $kind certificate didn't import. Nothing was uploaded."
        exit 1
    fi
    # Your login keychain keeps a copy: it's the backup, and lets this Mac sign too
    if security import "$WORK/$kind.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$P12_PASSWORD" \
            -T /usr/bin/codesign -T /usr/bin/productbuild >/dev/null 2>&1; then
        print "Saved to your login keychain as \"${NAMES[$kind]}\"."
    else
        print "Couldn't add \"${NAMES[$kind]}\" to your login keychain. That's fine: the secret is what releases use."
    fi
done
security delete-keychain "$TEST_KEYCHAIN"

# MARK: Notarization

step "4. Make an app-specific password for notarizing"
print "Opening account.apple.com. There:"
print "  a. Sign in, then open Sign-In and Security, then App-Specific Passwords."
print "  b. Click + (or Generate), name it 'Jared's Mac App notarization', and copy the password."
open "https://account.apple.com/account/manage"

can_check=0
xcrun --find notarytool >/dev/null 2>&1 && can_check=1
while true; do
    print
    ask_hidden NOTARY_PASSWORD "Paste the app-specific password and press Return (it stays hidden): "
    [[ -z "$NOTARY_PASSWORD" ]] && continue
    (( can_check )) || break
    print "Checking it with Apple..."
    if output="$(xcrun notarytool history --apple-id "$APPLE_ID" --password "$NOTARY_PASSWORD" \
            --team-id "$EXPECTED_TEAM" 2>&1)"; then
        print "Apple accepted it."
        break
    fi
    fail "Apple didn't accept it:"
    print -r -- "$output" | tail -3 >&2
    ask answer "Apple ID [$APPLE_ID] (press Return to keep it): "
    [[ -n "$answer" ]] && APPLE_ID="$answer"
done

# MARK: Secrets

step "5. Add the secrets to $REPO"
set_secret() {
    if (( USE_GH )); then
        printf '%s' "$2" | gh secret set "$1" --repo "$REPO"
    else
        printf '%s' "$2" | pbcopy
        USED_CLIPBOARD=1
        open "https://github.com/$REPO/settings/secrets/actions/new"
        print "In the page that opened: Name $1, paste into Secret (it's on your clipboard), click Add secret."
        ask answer "Then press Return here. "
    fi
}
set_secret DEVELOPER_ID_APP_P12 "$(base64 -i "$WORK/Application.p12")"
set_secret DEVELOPER_ID_INSTALLER_P12 "$(base64 -i "$WORK/Installer.p12")"
set_secret DEVELOPER_ID_P12_PASSWORD "$P12_PASSWORD"
set_secret NOTARY_APPLE_ID "$APPLE_ID"
set_secret NOTARY_PASSWORD "$NOTARY_PASSWORD"

print
print -P "%BDone.%b The next release is signed by team $EXPECTED_TEAM and notarized."
print "The temporary files are deleted. Your login keychain keeps the certificates as your backup."
