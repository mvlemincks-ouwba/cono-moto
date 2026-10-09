#!/usr/bin/env bash
# Prépare une session du panel de clients IA ou du CTPO : Flutter, dépendances,
# polices Barlow et captures d'écran de l'appli (tool/screenshots/out/*.png).
#
#   bash tool/clients/prepare.sh             # tout
#   bash tool/clients/prepare.sh --no-shots  # sans les captures
#
# Le PATH ne remonte pas au shell appelant : préfixe ensuite tes commandes par
#   export PATH=/opt/flutter-sdk/flutter/bin:$PATH
set -euo pipefail
cd "$(dirname "$0")/../.."

FLUTTER_VERSION=3.47.6
if ! command -v flutter >/dev/null 2>&1; then
  if [ ! -x /opt/flutter-sdk/flutter/bin/flutter ]; then
    echo "Installation de Flutter $FLUTTER_VERSION…"
    mkdir -p /opt/flutter-sdk
    curl -fsSL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
      | tar -xJ -C /opt/flutter-sdk
  fi
  export PATH=/opt/flutter-sdk/flutter/bin:$PATH
fi
flutter --version | head -1
flutter pub get >/dev/null

[ "${1:-}" = "--no-shots" ] && exit 0

FONTS=${FONTS_DIR:-$HOME/.cache/cono-moto/fonts}
mkdir -p "$FONTS"
for f in Barlow-Regular Barlow-Medium Barlow-SemiBold Barlow-Bold Barlow-ExtraBold; do
  [ -s "$FONTS/$f.ttf" ] || curl -fsSL -o "$FONTS/$f.ttf" "https://raw.githubusercontent.com/google/fonts/main/ofl/barlow/$f.ttf"
done
for f in BarlowCondensed-SemiBold BarlowCondensed-Bold; do
  [ -s "$FONTS/$f.ttf" ] || curl -fsSL -o "$FONTS/$f.ttf" "https://raw.githubusercontent.com/google/fonts/main/ofl/barlowcondensed/$f.ttf"
done

echo "Captures d'écran (données fictives)…"
rm -rf tool/screenshots/out
# google_fonts se plaint à la fin (polices chargées à la main) : seules les
# images comptent.
flutter test tool/screenshots/screens_test.dart --update-goldens --dart-define=FONTS_DIR="$FONTS" >/dev/null 2>&1 || true
ls -1 tool/screenshots/out/*.png
