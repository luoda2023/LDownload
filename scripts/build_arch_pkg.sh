#!/bin/bash
# Usage: ./scripts/build_arch_pkg.sh <version>
# Example: ./scripts/build_arch_pkg.sh 0.1.24
# Full build: flutter + cargo (NMH) → assemble arch_pkg/ → .pkg.tar.zst

set -e

VERSION="${1:?Usage: $0 <version>}"
PKGREL="1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_DIR="$ROOT/build/linux/x64/release/bundle"
PKG_DIR="$ROOT/arch_pkg"
OUTPUT_DIR="$ROOT/build/installer"
OUTPUT="${OUTPUT_DIR}/LDownload-${VERSION}-linux-x64.pkg.tar.zst"

cd "$ROOT"

# ── 1. Build Flutter Linux app ──
echo "[1/4] Building Flutter Linux app (v${VERSION})..."
flutter build linux --release \
  --build-name="$VERSION" \
  --build-number=1 \
  --dart-define=APP_VERSION="$VERSION"

# ── 2. Build NMH relay binary ──
echo "[2/4] Building NMH relay binary..."
cargo build --release -p ldown_nmh
cp target/release/ldown_nmh "$BUNDLE_DIR/"
chmod +x "$BUNDLE_DIR/ldown_nmh"

# ── 3. Assemble arch_pkg/ ──
echo "[3/4] Assembling package layout..."

rm -rf "$PKG_DIR/opt" "$PKG_DIR/usr"
mkdir -p "$PKG_DIR/opt/ldownload"
mkdir -p "$PKG_DIR/usr/bin"
mkdir -p "$PKG_DIR/usr/share/applications"
mkdir -p "$PKG_DIR/usr/share/icons/hicolor/256x256/apps"

# Flutter bundle → /opt/ldownload/
cp -a "$BUNDLE_DIR/." "$PKG_DIR/opt/ldownload/"

# /usr/bin/ldownload wrapper script
cat > "$PKG_DIR/usr/bin/ldownload" << 'WRAPPER'
#!/bin/bash
exec /opt/ldownload/ldownload "$@"
WRAPPER
chmod 755 "$PKG_DIR/usr/bin/ldownload"

# .desktop and icon to standard XDG paths
cp linux/com.ldownload.app.desktop "$PKG_DIR/usr/share/applications/"
cp assets/logo/ldownload_logo.png \
  "$PKG_DIR/usr/share/icons/hicolor/256x256/apps/com.ldownload.app.png"

# ── 4. Write .PKGINFO and pack ──
echo "[4/4] Creating .pkg.tar.zst..."

INSTALLED_SIZE=$(du -sb "$PKG_DIR/opt/" "$PKG_DIR/usr/" | awk '{sum+=$1} END {print sum}')

cat > "$PKG_DIR/.PKGINFO" << EOF
pkgname = ldownload
pkgver = ${VERSION}-${PKGREL}
pkgdesc = Free IDM-alternative download manager
url = https://dicad.cn
builddate = $(date +%s)
packager = LDownload CI <ci@ldownload.app>
size = ${INSTALLED_SIZE}
arch = x86_64
license = custom
depend = gtk3
depend = libnotify
EOF

mkdir -p "$OUTPUT_DIR"
cd "$PKG_DIR"
tar --zstd --owner=0 --group=0 -cf "$OUTPUT" .PKGINFO opt/ usr/

echo ""
echo "Done: $OUTPUT"
echo "Install with: sudo pacman -U $OUTPUT"
