#!/usr/bin/env bash
# Real war engine test: run org.beangle.otk:beangle-otk-ws:war:0.0.29 with the
# built-in tomcat engine end-to-end.
#
# Verifies: gav war 解析下载依赖（sha1 校验）、爆炸布局、exec 引擎 Bootstrap、
# Tomcat 启动、HTTP 响应、优雅关闭后 docBase 被引擎清理。
#
# Requires: network (first run downloads ~100MB into the local repo), java 17+
# (tomcat 11), curl, and a built jstart (target/jstart).
#
# Usage:
#   bash test/war-run-test.sh [--local=<repo>] [--port=<port>] [--path=/]
#                             [--engine=tomcat|undertow] [--keep]
#
# The local repo defaults to ~/.m2/repository so reruns are served from cache.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JSTART="$ROOT/target/jstart"
REPO="${HOME}/.m2/repository"
GAV="org.beangle.otk:beangle-otk-ws:war:0.0.29"
CPATH="/"
PORT=$((20000 + RANDOM % 20000))
ENGINE="tomcat"
KEEP=0

for a in "$@"; do
  case "$a" in
    --local=*) REPO="${a#*=}" ;;
    --port=*) PORT="${a#*=}" ;;
    --path=*) CPATH="${a#*=}" ;;
    --engine=*) ENGINE="${a#*=}" ;;
    --keep) KEEP=1 ;;
    *) echo "unknown option $a" >&2; exit 2 ;;
  esac
done

case "$ENGINE" in
  tomcat) ENGINE_JAR="tomcat-embed-core-11.0.21.jar"; STARTED_LOG="Tomcat started" ;;
  undertow) ENGINE_JAR="undertow-core-2.3.24.Final.jar"; STARTED_LOG="Undertow started" ;;
  *) echo "unknown engine $ENGINE (tomcat|undertow)" >&2; exit 2 ;;
esac

if [ ! -x "$JSTART" ]; then
  echo "Cannot find $JSTART, run 'dub build -b release' first." >&2
  exit 1
fi

T="$(mktemp -d /tmp/jstart-war-test.XXXXXX)"
BASE="$T/sas"
LOG="$T/run.log"
failures=0

cleanup() {
  if [ -n "${JPID:-}" ] && kill -0 "$JPID" 2>/dev/null; then
    kill -TERM "$JPID" 2>/dev/null
    wait "$JPID" 2>/dev/null
  fi
  if [ "$KEEP" -eq 0 ]; then
    rm -rf "$T"
  else
    echo "kept $T (log: $LOG)"
  fi
}
trap cleanup EXIT

check() {
  local desc="$1" cond="$2"
  if eval "$cond"; then
    echo "ok   $desc"
  else
    echo "FAIL $desc" >&2
    failures=$((failures + 1))
  fi
}

echo "== resolve war gav =="
out="$("$JSTART" --local="$REPO" --quiet resolve "$GAV")"; code=$?
check "resolve exit=0" "[ $code -eq 0 ]"
check "resolve outputs .war" "printf '%s' \"$out\" | grep -q 'beangle-otk-ws-0.0.29.war'"

echo "== run with built-in $ENGINE engine =="
echo "port=$PORT path=$CPATH repo=$REPO engine=$ENGINE"
cat > "$T/app.launch" <<INI
[app]
entry = $GAV
engine = $ENGINE

[args]
--path=$CPATH
INI
"$JSTART" --local="$REPO" run "$T/app.launch" --port="$PORT" --base="$BASE" >"$LOG" 2>&1 &
JPID=$!

code=000
waited=0
while [ "$waited" -lt 240 ]; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT$CPATH" 2>/dev/null)"
  if [ "$code" != "000" ]; then
    break
  fi
  if ! kill -0 "$JPID" 2>/dev/null; then
    echo "server exited early, see $LOG" >&2
    break
  fi
  sleep 1
  waited=$((waited + 1))
done
check "engine answers http (code=$code)" "[ \"$code\" != '000' ]"
check "log: $ENGINE started" "grep -q '$STARTED_LOG' \"$LOG\""
check "log: beangle app booted" "grep -Eq 'ROOT started|Action scan completed' \"$LOG\""
check "exploded docBase present" "[ -d \"$BASE/webapps/ROOT\" ]"
check "engine jars on classpath" "grep -q '$ENGINE_JAR' \"$LOG\""

echo "== graceful shutdown =="
kill -TERM "$JPID" 2>/dev/null
wait "$JPID" 2>/dev/null
JPID=
sleep 1
check "engine cleaned docBase on shutdown" "[ ! -d \"$BASE/webapps/ROOT\" ]"

if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures check(s), log: $LOG" >&2
  exit 1
fi
echo "all checks passed (log: $LOG)"
