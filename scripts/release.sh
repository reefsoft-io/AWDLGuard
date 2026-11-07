#!/bin/zsh
# Builds, notarises and publishes an AWDL Guard release. See docs/DEVELOPMENT.md.
#
#   scripts/release.sh <version>            release: tag v<version> and publish it
#   scripts/release.sh <version> --dry-run  everything up to the notarised zip, without
#                                           the git checks, the tag or the release
#
# Nothing private lives here. The team comes from the project's build settings, the
# notarisation credentials from the Keychain profile below, and publishing from gh's login.

set -euo pipefail

readonly notary_profile=AWDLGuard
readonly root=${0:A:h:h}
readonly work=$root/build/release
readonly usage="usage: scripts/release.sh <x.y.z> [--dry-run]"

step() { print -P "%B==> $1%b" }
fail() { print -u2 "error: $1"; exit 1 }

# Arguments are parsed strictly, so a mistyped --dry-run can't make a real release.
(( $# == 1 || $# == 2 )) || fail $usage
version=$1
is_dry_run=false
if (( $# == 2 )); then
    [[ $2 == --dry-run ]] || fail $usage
    is_dry_run=true
fi
[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail $usage
cd $root

step "Checking"
settings=$(xcodebuild -project AWDLGuard.xcodeproj -scheme AWDLGuard -configuration Release -showBuildSettings 2>&1) \
    || fail "couldn't read the project's build settings:\n$settings"
setting() { print -r -- $settings | awk -v key=$1 '$1 == key && value == "" { value = $3 } END { print value }' }
[[ $(setting MARKETING_VERSION) == $version ]] \
    || fail "the project's MARKETING_VERSION is $(setting MARKETING_VERSION); bump it to $version and commit first"
team=$(setting DEVELOPMENT_TEAM)
[[ -n $team ]] || fail "no DEVELOPMENT_TEAM is set for the project"
security find-identity -v -p codesigning | grep -q "Developer ID Application: .*($team)" \
    || fail "no Developer ID Application certificate for team $team in the Keychain"
xcrun notarytool history --keychain-profile $notary_profile >/dev/null 2>&1 \
    || fail "notarytool profile '$notary_profile' didn't work: it's missing, or the Mac is offline. To create it, run: xcrun notarytool store-credentials $notary_profile"
if ! $is_dry_run; then
    [[ -z $(git status --porcelain) ]] || fail "the working tree has uncommitted changes"
    [[ $(git branch --show-current) == main ]] || fail "releases are made from main"
    git fetch --quiet origin main || fail "couldn't fetch origin"
    [[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || fail "main isn't level with origin/main"
    remote_tags=$(git ls-remote --tags origin "refs/tags/v$version") || fail "couldn't read origin's tags"
    [[ -z $(git tag --list v$version) && -z $remote_tags ]] || fail "tag v$version already exists"
    gh auth status >/dev/null 2>&1 || fail "gh isn't logged in; run: gh auth login"
    gh repo view >/dev/null 2>&1 || fail "gh can't reach this repository"
fi
# Every release gets a higher build number than the last, without a manual bump.
build_number=$(git rev-list --count HEAD)

rm -rf $work
mkdir -p $work

step "Testing"
xcodebuild -project AWDLGuard.xcodeproj -scheme AWDLGuard -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath $work/DerivedData -quiet test

step "Archiving $version ($build_number)"
xcodebuild -project AWDLGuard.xcodeproj -scheme AWDLGuard -configuration Release -destination generic/platform=macOS \
    -derivedDataPath $work/DerivedData -archivePath $work/AWDLGuard.xcarchive -quiet archive \
    DEVELOPMENT_TEAM=$team CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
    OTHER_CODE_SIGN_FLAGS=--timestamp CURRENT_PROJECT_VERSION=$build_number
# The archived app is already signed for Developer ID, so it's taken as is.
app=$work/AWDL\ Guard.app
ditto "$work/AWDLGuard.xcarchive/Products/Applications/AWDL Guard.app" $app

step "Checking signatures"
codesign --verify --deep --strict $app
for binary in $app "$app/Contents/MacOS/AWDLGuardHelper"; do
    details=$(codesign -dvv $binary 2>&1)
    for expected in "Authority=Developer ID Application" "TeamIdentifier=$team" "Timestamp=" "(runtime)"; do
        [[ $details == *$expected* ]] || fail "${binary:t} is missing $expected in its signature"
    done
done

step "Notarising"
ditto -c -k --keepParent $app $work/notarise.zip
submission=$(xcrun notarytool submit $work/notarise.zip --keychain-profile $notary_profile --wait --output-format plist) \
    || fail "notarytool submit failed:\n$submission"
notary_status=$(print -r -- $submission | plutil -extract status raw - 2>/dev/null) \
    || fail "couldn't read notarytool's result:\n$submission"
if [[ $notary_status != Accepted ]]; then
    submission_id=$(print -r -- $submission | plutil -extract id raw - 2>/dev/null || true)
    [[ -n $submission_id ]] && xcrun notarytool log $submission_id --keychain-profile $notary_profile
    fail "notarisation finished as '$notary_status', not Accepted"
fi

step "Stapling"
xcrun stapler staple $app
xcrun stapler validate $app
spctl --assess --type execute $app
zip=$work/AWDL-Guard-$version.zip
ditto -c -k --keepParent $app $zip
print "SHA-256: $(shasum -a 256 $zip | cut -d' ' -f1)"

if $is_dry_run; then
    print "Dry run complete: $zip"
    exit 0
fi

step "Publishing"
git tag -a v$version -m "AWDL Guard $version"
if ! git push origin v$version; then
    git tag -d v$version
    fail "couldn't push tag v$version; the local tag was removed, so the script can run again"
fi
gh release create v$version $zip --verify-tag --title "AWDL Guard $version" --generate-notes \
    || fail "tag v$version is pushed but the release wasn't created. Finish it with:
  gh release create v$version '$zip' --verify-tag --title 'AWDL Guard $version' --generate-notes"
print "Released AWDL Guard $version"
