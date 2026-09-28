#!/usr/bin/env bash
set -euo pipefail
ROOT="$(realpath "${1:?source root required}")"
VERSION="${2:?Debian version required}"
OUT_DEB="$(realpath -m "${3:?output .deb required}")"
DEB_ARCH=amd64
dpkg --validate-version "$VERSION"
[[ -f "$ROOT/flutter/build/linux/x64/release/bundle/lib/librustdesk.so" ]]
mkdir -p "$(dirname "$OUT_DEB")"
EXTRA_DEPENDS=""
if [[ "${DEB_ARCH}" == "armhf" ]]; then
  EXTRA_DEPENDS=", libatomic1"
fi
PKG_ROOT="$(mktemp -d /tmp/mdesk-deb.XXXXXX)"
trap 'rm -rf -- "$PKG_ROOT"' EXIT
mkdir -p \
  "$PKG_ROOT/usr/share/rustdesk" \
  "$PKG_ROOT/usr/share/rustdesk/files/systemd" \
  "$PKG_ROOT/usr/share/icons/hicolor/256x256/apps" \
  "$PKG_ROOT/usr/share/icons/hicolor/scalable/apps" \
  "$PKG_ROOT/usr/share/applications" \
  "$PKG_ROOT/usr/share/polkit-1/actions" \
  "$PKG_ROOT/etc/rustdesk" \
  "$PKG_ROOT/etc/pam.d" \
  "$PKG_ROOT/DEBIAN"
cp -a "$ROOT/flutter/build/linux/x64/release/bundle/." "$PKG_ROOT/usr/share/rustdesk/"
cp "$ROOT/res/rustdesk.service" "$PKG_ROOT/usr/share/rustdesk/files/systemd/"
cp "$ROOT/res/mdesk.png" "$PKG_ROOT/usr/share/icons/hicolor/256x256/apps/mdesk.png"
cp "$ROOT/res/mdesk.svg" "$PKG_ROOT/usr/share/icons/hicolor/scalable/apps/mdesk.svg"
cp "$ROOT/res/mdesk.desktop" "$PKG_ROOT/usr/share/applications/mdesk.desktop"
cp "$ROOT/res/mdesk-link.desktop" "$PKG_ROOT/usr/share/applications/mdesk-link.desktop"
cp "$ROOT/res/startwm.sh" "$PKG_ROOT/etc/rustdesk/"
cp "$ROOT/res/xorg.conf" "$PKG_ROOT/etc/rustdesk/"
cp "$ROOT/res/pam.d/rustdesk.debian" "$PKG_ROOT/etc/pam.d/rustdesk"
printf '#!/bin/sh\n' > "$PKG_ROOT/usr/share/rustdesk/files/polkit"
chmod a+x "$PKG_ROOT/usr/share/rustdesk/files/polkit"
cp -a "$ROOT/res/DEBIAN/." "$PKG_ROOT/DEBIAN/"
find "$PKG_ROOT/DEBIAN" -type f -exec sed -i 's/\r$//' {} +
cat > "$PKG_ROOT/DEBIAN/control" <<EOF
Package: mdesk
Section: net
Priority: optional
Version: ${VERSION}
Architecture: ${DEB_ARCH}
Maintainer: metadatalab <metadtlab@gmail.com>
Homepage: https://www.mdesk.co.kr
Depends: libgtk-3-0, libxcb-randr0, libxdo3, libxfixes3, libxcb-shape0, libxcb-xfixes0, libasound2, libsystemd0, curl, libva2, libva-drm2, libva-x11-2, libgstreamer-plugins-base1.0-0, libpam0g, gstreamer1.0-pipewire${EXTRA_DEPENDS}
Recommends: libayatana-appindicator3-1
Provides: rustdesk
Conflicts: rustdesk
Replaces: rustdesk
Description: A remote control software.

EOF
rm -f "$PKG_ROOT/DEBIAN/md5sums"
(
  cd "$PKG_ROOT"
  find . -type f ! -path './DEBIAN/*' -print0 | sort -z | xargs -0 md5sum | sed 's#  ./#  /#' > DEBIAN/md5sums
)
chmod -R 755 "$PKG_ROOT/DEBIAN"
dpkg-deb --root-owner-group -b "$PKG_ROOT" "$OUT_DEB"
echo "Package ready: $OUT_DEB"
