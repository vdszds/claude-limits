#!/bin/zsh
# Publishes a release: a signed, notarized Claude-Limits.dmg for Apple silicon and Intel on GitHub Releases,
# and the Homebrew cask in vdszds/homebrew-tap pointing at it.
#
#   ./release.sh 1.0.0
#
# Needs a Developer ID Application certificate in the keychain, gh signed in, and notarization credentials saved once:
#   xcrun notarytool store-credentials claude-limits --apple-id <email> --team-id <team>
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version>, for example 1.0.0}"
TAG="v$VERSION"
REPO=vdszds/claude-limits
TAP=vdszds/homebrew-tap
PROFILE="${NOTARY_PROFILE:-claude-limits}"
OUT=build/release
APP="$OUT/Claude Limits.app"
DMG="$OUT/Claude-Limits.dmg"

# Check everything that can fail before spending minutes on a build and notarization.
IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -1)"
[[ -n "$IDENTITY" ]] || { echo "No Developer ID Application certificate in the keychain."; exit 1; }
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null || { echo "Save notarization credentials as \"$PROFILE\" first (see the top of this script)."; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first."; exit 1; }
git fetch -q origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "Push main first, so the release tag matches GitHub."; exit 1; }
! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "$TAG already exists."; exit 1; }

swift build -c release --arch arm64 --arch x86_64
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Limits" "$APP/Contents/MacOS/Limits"
cp Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$(git rev-list --count HEAD)" "$APP/Contents/Info.plist"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"

# A disk image with an Applications shortcut, so installing is one drag.
mkdir "$OUT/dmg"
cp -R "$APP" "$OUT/dmg/"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -volname "Claude Limits" -srcfolder "$OUT/dmg" -format UDZO -ov "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

# Notarizing the disk image covers the app inside it too.
RESULT="$(xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait --output-format json)"
if [[ "$RESULT" != *'"status":"Accepted"'* ]]; then
  echo "Notarization failed: $RESULT"
  ID="$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' <<< "$RESULT")"
  [[ -n "$ID" ]] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE"
  exit 1
fi
xcrun stapler staple -q "$DMG"
spctl --assess --type open --context context:primary-signature "$DMG"
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"

git tag "$TAG"
git push -q origin "$TAG"
gh release create "$TAG" "$DMG" --repo "$REPO" --title "Claude Limits $VERSION" --generate-notes --verify-tag

# Point the Homebrew cask at the new release. Commits there use this repo's git identity.
gh repo view "$TAP" >/dev/null 2>&1 || gh repo create "$TAP" --public --description "Homebrew casks by vdszds"
TAP_DIR="$(mktemp -d)"
gh repo clone "$TAP" "$TAP_DIR" -- -q
mkdir -p "$TAP_DIR/Casks"
cat > "$TAP_DIR/Casks/claude-limits.rb" <<EOF
cask "claude-limits" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$REPO/releases/download/v#{version}/Claude-Limits.dmg"
  name "Claude Limits"
  desc "Menu bar usage limits for several Claude accounts"
  homepage "https://github.com/$REPO"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Claude Limits.app"

  uninstall quit: "com.vzdesenko.Limits"

  zap trash: [
    "~/Library/Caches/com.vzdesenko.Limits",
    "~/Library/HTTPStorages/com.vzdesenko.Limits",
    "~/Library/Preferences/com.vzdesenko.Limits.plist",
    "~/Library/WebKit/com.vzdesenko.Limits",
  ]
end
EOF
git -C "$TAP_DIR" add Casks/claude-limits.rb
git -C "$TAP_DIR" -c user.name="$(git config user.name)" -c user.email="$(git config user.email)" commit -q -m "claude-limits $VERSION"
git -C "$TAP_DIR" push -q origin HEAD:main
rm -rf "$TAP_DIR"

echo "Released $TAG: https://github.com/$REPO/releases/tag/$TAG"
echo "Homebrew: brew install --cask vdszds/tap/claude-limits"
