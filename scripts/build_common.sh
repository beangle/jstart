#!/bin/bash
# 打包脚本共用：清空 dub 产物与 target/ 后 release 构建。

# 包版本号：以 git tag 为唯一来源（如 v0.0.1 -> 0.0.1）。
# dub 的版本号由 tag（正式版本）/分支（~分支名 滚动版本）决定，recipe 里的
# "version" 字段属过时写法，registry 会因此拒收分支版本，故不再从 dub.json 读取。
#
# 取不到就报错退出，并把 git 自己的输出一并打出来：脚本不能再自己咽掉原因——
# 「HEAD 上没有可达 tag」和「git 压根没跑起来」（浅克隆没取 tag、safe.directory
# 把人拦下、PATH 里没有 git）是两码事，排障成本差很远。
jstart_package_version() {
  local root="${JSTART_HOME:?JSTART_HOME not set}"
  local ver="" detail="" commit="" ntags=""

  if command -v git >/dev/null 2>&1; then
    # 最近的可达 tag；失败时留下 git 的原话当诊断信息
    ver="$(git -C "$root" describe --tags --abbrev=0 2>/dev/null || true)"
    if [ -z "$ver" ]; then
      detail="$(git -C "$root" describe --tags 2>&1 || true)"
    fi
  else
    detail="git: command not found"
  fi

  ver="${ver#v}"
  if [ -z "$ver" ]; then
    commit="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || true)"
    ntags="$(git -C "$root" tag -l 2>/dev/null | wc -l || true)"
    echo "==========================================================" >&2
    echo "Could not determine version from git tag" >&2
    echo "（请在仓库里打 tag，如：git tag v0.0.1）" >&2
    if [ -n "$detail" ]; then
      echo "$detail" >&2
    fi
    echo "repo: commit=${commit:-?}, tags=${ntags:-?}" >&2
    echo "提示：tag 没取全时先 fetch（浅克隆要 unshallow），再重跑。" >&2
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
