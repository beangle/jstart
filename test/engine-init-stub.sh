#!/usr/bin/env bash
# 最小 `[engine] init` 命令（jstart 自带，只给 test/war-run-test.sh 用）。
#
# 它演示 `docs/engine.md` 的协议：读 jstart 写出的两个 classpath 文件，解压 war 到
# docBase，再把最终启动命令（NUL 分隔 argv）写进 --entry-out，由 jstart exec。
# 真实环境里这一步由外部引擎工具负责，jstart 自身不内置任何容器。
#
# Usage: engine-init-stub.sh <tomcat|undertow> --base=<dir> --entry=<war|dir>
#          --engine-classpath-file=<file> --app-classpath-file=<file>
#          --local-repo=<dir> --entry-out=<file>
#          [--app-jvm-arg=<opt>]... [--path=<ctx>] [--port=<n>] [args...]
set -eu

if [ $# -lt 1 ]; then
  echo "usage: $0 <tomcat|undertow> [init protocol args]" >&2
  exit 2
fi
TYPE="$1"
shift

case "$TYPE" in
  tomcat) MAIN="org.beangle.bas.engine.tomcat.Bootstrap" ;;
  undertow) MAIN="org.beangle.bas.engine.undertow.Bootstrap" ;;
  *) echo "unknown engine type $TYPE (tomcat|undertow)" >&2; exit 2 ;;
esac

BASE=""; ENTRY=""; ENTRY_OUT=""; ENGINE_CP_FILE=""; APP_CP_FILE=""; LOCAL_REPO=""
PATH_ARG=""; PORT_ARG=""
APP_JVM_ARGS=(); OTHER=()
for a in "$@"; do
  case "$a" in
    --base=*) BASE="${a#*=}" ;;
    --entry=*) ENTRY="${a#*=}" ;;
    --entry-out=*) ENTRY_OUT="${a#*=}" ;;
    --engine-classpath-file=*) ENGINE_CP_FILE="${a#*=}" ;;
    --app-classpath-file=*) APP_CP_FILE="${a#*=}" ;;
    --local-repo=*) LOCAL_REPO="${a#*=}" ;;
    --app-jvm-arg=*) APP_JVM_ARGS+=("${a#*=}") ;;
    --path=*) PATH_ARG="${a#*=}" ;;
    --port=*) PORT_ARG="${a#*=}" ;;
    *) OTHER+=("$a") ;;
  esac
done
if [ -z "$BASE" ] || [ -z "$ENTRY" ] || [ -z "$ENTRY_OUT" ]; then
  echo "missing --base/--entry/--entry-out" >&2
  exit 2
fi

# docBase：<base>/webapps/<ROOT|a#b>；--path 归一化去尾 /、折叠 //。
ctx="${PATH_ARG:-/}"
while [ "${ctx%\/}" != "$ctx" ] && [ "$ctx" != "/" ]; do ctx="${ctx%/}"; done
while [ "${ctx//\/\//\/}" != "$ctx" ]; do ctx="${ctx//\/\//\/}"; done
if [ -z "$ctx" ] || [ "$ctx" = "/" ]; then
  DOCBASE_NAME="ROOT"
else
  case "$ctx" in /*) ;; *) ctx="/$ctx" ;; esac
  DOCBASE_NAME="$(printf '%s' "${ctx#/}" | tr '/' '#')"
fi

if [ -d "$ENTRY" ]; then
  DOCBASE="$(cd "$ENTRY" && pwd)"
else
  DOCBASE="$BASE/webapps/$DOCBASE_NAME"
  rm -rf "$DOCBASE"
  mkdir -p "$DOCBASE"
  unzip -q -o "$ENTRY" -d "$DOCBASE"
fi
mkdir -p "$DOCBASE/WEB-INF/classes"

CP=""
add_cp() { if [ -n "$1" ]; then CP="${CP:+$CP:}$1"; fi; }
[ -n "$ENGINE_CP_FILE" ] && [ -s "$ENGINE_CP_FILE" ] && add_cp "$(cat "$ENGINE_CP_FILE")"
[ -n "$APP_CP_FILE" ] && [ -s "$APP_CP_FILE" ] && add_cp "$(cat "$APP_CP_FILE")"
add_cp "$DOCBASE/WEB-INF/classes"
if [ -d "$DOCBASE/WEB-INF/lib" ]; then
  for jar in "$DOCBASE"/WEB-INF/lib/*.jar; do [ -f "$jar" ] && add_cp "$jar"; done
fi

ARGV=(java)
[ "${#APP_JVM_ARGS[@]}" -gt 0 ] && ARGV+=("${APP_JVM_ARGS[@]}")
ARGV+=("-Dbas.home=$BASE")
[ -n "$LOCAL_REPO" ] && ARGV+=("-Dbas.repo=$LOCAL_REPO")
ARGV+=(-cp "$CP" "$MAIN" "--base=$BASE" "--docBase=$DOCBASE")
[ -n "$PATH_ARG" ] && ARGV+=("--path=$PATH_ARG")
[ -n "$PORT_ARG" ] && ARGV+=("--port=$PORT_ARG")
[ "${#OTHER[@]}" -gt 0 ] && ARGV+=("${OTHER[@]}")

printf '%s\0' "${ARGV[@]}" > "$ENTRY_OUT"
echo "Engine entry ready: $DOCBASE -> $ENTRY_OUT" >&2
