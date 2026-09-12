#!/bin/bash
# 打包脚本共用：清空 dub 产物与 target/ 后 release 构建。

# 包版本号：以 git tag 为唯一来源（如 v0.0.1 -> 0.0.1）。
# dub 的版本号由 tag（正式版本）/分支（~分支名 滚动版本）决定，recipe 里的
# "version" 字段属过时写法，registry 会因此拒收分支版本，故不再从 dub.json 读取。
jstart_package_version() {
  local root="${JSTART_HOME:?JSTART_HOME not set}"
  local ver
  ver="$(git -C "$root" describe --tags --abbrev=0 2>/dev/null || true)"
  ver="${ver#v}"
  if [ -z "$ver" ]; then
    echo "==========================================================" >&2
    echo "Could not determine version from git tag" >&2
    echo "（请在仓库里打 tag，如：git tag v0.0.1）" >&2
    echo "==========================================================" >&2
    exit 1
  fi
  printf '%s' "$ver"
}

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
