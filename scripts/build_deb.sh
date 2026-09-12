#!/bin/bash
# Debian/Ubuntu 打包脚本。需在 Debian 系系统运行，或安装 dpkg：apt install dpkg-dev fakeroot
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export JSTART_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$JSTART_HOME"

set -e -o pipefail
# shellcheck source=build_common.sh
source "$SCRIPT_DIR/build_common.sh"

ferror(){
  echo "==========================================================" >&2
  echo $1 >&2
  echo $2 >&2
  echo "==========================================================" >&2
  exit 1
}

E=0
LIST=""
fcheck(){
  if ! command -v "$1" >/dev/null 2>&1; then
    LIST=$LIST" "$1
    E=1
  fi
}
fcheck dpkg-deb
fcheck fakeroot
fcheck strip
fcheck dub
if [ $E -eq 1 ]; then
  ferror "Missing commands on your system:" "$LIST"
fi

jstart_prepare_release_build

MAINTAINER="duantihua <duantihua@163.com>"
VERSION=`awk -F'"' '/"version"/{print $4; exit}' $JSTART_HOME/dub.json`
REVISION="1"
[[ -n "$1" ]] && REVISION="$1"
DESTDIR="$JSTART_HOME/target"
ARCH="amd64"
DEBFILE="jstart_${VERSION}-${REVISION}_${ARCH}.deb"
PKGDIR="$DESTDIR/jstart_${VERSION}-${REVISION}_${ARCH}"

rm -rf -f "$DESTDIR/$DEBFILE"
rm -rf "$PKGDIR"

mkdir -p "$PKGDIR"
pushd "$PKGDIR" > /dev/null

# 定位为命令而非系统服务：仅安装 /usr/bin/jstart，无 systemd 单元、无默认配置
mkdir -p usr/bin
cp -f $JSTART_HOME/target/jstart usr/bin/jstart
strip --strip-unneeded usr/bin/jstart
chmod 0755 usr/bin/jstart

# DEBIAN 控制文件
mkdir -p DEBIAN

# control
cat > DEBIAN/control << EOF
Package: jstart
Version: ${VERSION}-${REVISION}
Section: utils
Priority: optional
Architecture: ${ARCH}
Maintainer: ${MAINTAINER}
Homepage: https://github.com/beangle/jstart
Depends: curl
Description: Lightweight Java artifact (jar/war) launcher written in D
 Resolve jar/war applications, download missing dependencies into the
 local maven repository, prepare the runtime environment and launch
 applications by exec'ing java.
 .
 Main designer: Duan TiHua
EOF

# CLI 工具：无 conffiles，也无需 preinst/postinst/prerm/postrm（无服务、无用户、无配置）

popd > /dev/null

# 构建 deb 包（-Zxz 压缩，不支持则用默认）
fakeroot dpkg-deb --build -Zxz "$PKGDIR" "$DESTDIR/$DEBFILE" 2>/dev/null || \
fakeroot dpkg-deb --build "$PKGDIR" "$DESTDIR/$DEBFILE"

rm -rf "$PKGDIR"

echo "Built: $DESTDIR/$DEBFILE"
