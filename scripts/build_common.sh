#!/bin/bash
# 打包脚本共用：清空 dub 产物与 target/ 后 release 构建。

jstart_prepare_release_build() {
  local root="${JSTART_HOME:?JSTART_HOME not set}"
  cd "$root" || exit 1
  echo "jstart: dub clean ..."
  if command -v dub >/dev/null 2>&1; then
    dub clean || true
  fi
  echo "jstart: removing target/ ..."
  rm -rf "$root/target"
  mkdir -p "$root/target"
  echo "jstart: dub build --build=release-nobounds --compiler=ldc2"
  dub build --build=release-nobounds --compiler=ldc2
}
