#!/bin/bash
# RPM 打包脚本。需安装 rpm-build、fakeroot；在 Fedora/RHEL 系系统运行
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export JSTART_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$JSTART_HOME"

set -e -o pipefail
# shellcheck source=build_common.sh
source "$SCRIPT_DIR/build_common.sh"

# error function
ferror(){
  echo "==========================================================" >&2
  echo $1 >&2
  echo $2 >&2
  echo "==========================================================" >&2
  exit 1
}
sys_release_version(){
  local os_id
  os_id=$(source /etc/os-release && echo "$ID")
  if [ "$os_id" == "fedora" ]; then
    REVISION="1.fc$(source /etc/os-release && echo "$VERSION_ID")"
  else
    REVISION="1.el$(source /etc/os-release && echo "$VERSION_ID")"
  fi
}

# needed commands function
E=0
LIST=""
fcheck(){
  if ! command -v "$1" >/dev/null 2>&1; then
    LIST=$LIST" "$1
    E=1
  fi
}
fcheck gzip
fcheck rpmbuild
fcheck fakeroot
fcheck strip
fcheck dub
if [ $E -eq 1 ]; then
    ferror "Missing commands on your system:" "$LIST"
fi

jstart_prepare_release_build

  # assign variables
  MAINTAINER="duantihua <duantihua@163.com>"
  VENDOR="Beangle"
  VERSION=`awk -F'"' '/"version"/{print $4; exit}' $JSTART_HOME/dub.json`
  REVISION=""
  if [ "$REVISION" == "" ]
  then
    sys_release_version
  fi
  DESTDIR="$JSTART_HOME/target"
  VERSION=$(sed 's/-/~/' <<<"$VERSION") # replace dash by tilde
  ARCH="x86_64"

  APPDIR="jstart-"$VERSION"-"$REVISION"."$ARCH
  RPMFILE="jstart-"$VERSION"-"$REVISION"."$ARCH".rpm"
  RPMDIR=$DESTDIR"/rpmbuild"

  rm -rf -f "$DESTDIR/$RPMFILE"
  rm -rf "$DESTDIR/$APPDIR"
  rm -rf "$RPMDIR"
  rm -rf -f "$DESTDIR/jstart.spec"
  # create temp dir
  mkdir -p $DESTDIR"/"$APPDIR
  # switch to temp dir
  pushd $DESTDIR"/"$APPDIR > /dev/null
    mkdir -p usr/bin
    cp -f $JSTART_HOME/target/jstart usr/bin/jstart
    strip --strip-unneeded usr/bin/jstart
    chmod 0755 usr/bin/jstart
    # change folders and files permissions
    chmod -R 0755 .

    # 运行时依赖：curl 负责下载（jstart 不再链接 libcurl）；java 仅 run 时按需使用，不作为安装依赖
    DEPEND="curl"
    # create jstart.spec file
    cd ..
    # Generate changelog
    changes=""
    if [ -f "$JSTART_HOME/CHANGELOG.md" ]; then
      # Read changelog from file
      while IFS= read -r line; do
        if [[ "$line" =~ ^##\ v ]]; then
            # Extract version and date
            VERSION_INFO=$(echo "$line" | sed 's/## v//')
            VERSION_PART=$(echo "$VERSION_INFO" | cut -d ' ' -f 1)
            DATE_PART=$(echo "$VERSION_INFO" | cut -d ' ' -f 2 | sed 's/[()]//g')
            # RPM %changelog 要求英文星期/月份；须 LC_ALL=C，否则中文环境会得到「三 1月…」而 rpmbuild 报错
            if [ -n "$DATE_PART" ]; then
              RPM_DATE=$(LC_ALL=C date -d "$DATE_PART" '+%a %b %d %Y' 2>/dev/null || LC_ALL=C date '+%a %b %d %Y')
            else
              RPM_DATE=$(LC_ALL=C date '+%a %b %d %Y')
            fi
            # Add changelog header with * prefix
            changes+="* $RPM_DATE $MAINTAINER - ${VERSION_PART}\n"

        elif [[ "$line" =~ ^- ]]; then
            # Add changelog entry with proper indentation
            changes+="  ${line}\n"
        fi
      done < "$JSTART_HOME/CHANGELOG.md"
    else
      # Default changelog with * prefix
      DATE=$(LC_ALL=C date '+%a %b %d %Y')
      changes="* $DATE $MAINTAINER - ${VERSION}-${REVISION}\n"
      changes+="  - Initial release of jstart\n"
      changes+="  - Resolve jar/war dependencies and prepare local maven repo\n"
      changes+="  - Run jar apps by executing java with forwarded args\n"
    fi
    # Ensure changelog is not empty and starts with *
    if [ -z "$changes" ]; then
      DATE=$(LC_ALL=C date '+%a %b %d %Y')
      changes="* $DATE $MAINTAINER - ${VERSION}-${REVISION}\n"
      changes+="  - No changelog available\n"
    fi

    echo -e 'Name: jstart
    Version: '$VERSION'
    Release: '$REVISION'
    Summary: Lightweight jar/war booter written in D
    Group: Development/Tools
    License: GPL-3.0-or-later
    URL: https://github.com/beangle/jstart
    Vendor: '$VENDOR'
    Packager: '$MAINTAINER'
    ExclusiveArch: '$ARCH'
    Requires: '$DEPEND'
    Provides: jstart('$ARCH') = '$VERSION-$REVISION'
    %description
    Lightweight jar/war booter written in D.
    Resolve jar/war applications, download missing dependencies into the
    local maven repository, prepare the runtime environment and launch
    applications by executing java.
    Main designer: Duan TiHua
    %changelog
    '$changes'
    %files' | sed 's/^    //' > jstart.spec

    # 定位为命令而非系统服务：只安装 /usr/bin/jstart，无 systemd 单元、
    # 无 %post/%preun 服务启停脚本、无独立用户
    find $DESTDIR/$APPDIR/ ! -type d | \
      sed 's|'$DESTDIR'/'$APPDIR'|/|' >> jstart.spec

    echo >> jstart.spec
    mkdir -p $RPMDIR
    echo "%define _rpmdir $RPMDIR" >> jstart.spec
    # create rpm file
    fakeroot rpmbuild --quiet --buildroot=$DESTDIR/$APPDIR -bb --target $ARCH --define '_binary_payload w9.xzdio' jstart.spec

    # disable pushd
    popd > /dev/null
    # place rpm package
    mv $RPMDIR/$ARCH/jstart-$VERSION-$REVISION.$ARCH.rpm $DESTDIR"/"$RPMFILE

    # delete temp dir
    rm -rf $RPMDIR
    rm -rf $DESTDIR"/"$APPDIR
    rm -rf -f $DESTDIR/jstart.spec

echo "Built: $DESTDIR/$RPMFILE"
