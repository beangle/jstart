#!/usr/bin/env bash
# Real war engine test: run org.beangle.otk:beangle-otk-ws:war:0.0.29 with the
# built-in tomcat engine end-to-end.
#
# Verifies: gav war 解析下载依赖（sha1 校验）、[engine] init 脚本准备 docBase（委托
# EmbedCreator）、exec 容器、Tomcat 启动、HTTP 响应、优雅关闭后 docBase 被引擎清理。
#
# Requires: network (first run downloads ~100MB into the local repo), java 17+
# (tomcat 11), curl, a built jstart (target/jstart), and a sas engine jar with
# the entry class (org.beangle.sas.engine.<name>.EmbedCreator, 0.14.0+).
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
  tomcat)
    ENGINE_JAR="tomcat-embed-core-11.0.21.jar"
    STARTED_LOG="Tomcat started"
    ENGINE_DEPS="org.beangle.sas:beangle-sas-engine:0.14.0
org.apache.tomcat.embed:tomcat-embed-core:11.0.21
org.apache.tomcat.embed:tomcat-embed-websocket:11.0.21"
    ;;
  undertow)
    ENGINE_JAR="undertow-core-2.4.4.Final.jar"
    STARTED_LOG="Undertow started"
    ENGINE_DEPS="org.beangle.sas:beangle-sas-engine:0.14.0
io.undertow:undertow-core:2.4.4.Final
io.undertow.ee:undertow-servlet:2.0.2.Final
io.undertow.ee:undertow-websockets:2.0.2.Final
org.jboss.logging:jboss-logging:3.6.3.Final
org.jboss.threads:jboss-threads:3.9.2
org.jboss.xnio:xnio-api:3.8.16.Final
org.jboss.xnio:xnio-nio:3.8.16.Final
jakarta.annotation:jakarta.annotation-api:2.1.1
jakarta.servlet:jakarta.servlet-api:6.1.0
jakarta.websocket:jakarta.websocket-api:2.2.0
jakarta.websocket:jakarta.websocket-client-api:2.2.0
org.wildfly.client:wildfly-client-config:1.0.1.Final
org.wildfly.common:wildfly-common:2.0.1
io.smallrye.common:smallrye-common-annotation:2.14.0
io.smallrye.common:smallrye-common-constraint:2.14.0
io.smallrye.common:smallrye-common-cpu:2.14.0
io.smallrye.common:smallrye-common-expression:2.14.0
io.smallrye.common:smallrye-common-function:2.14.0
io.smallrye.common:smallrye-common-net:2.14.0
io.smallrye.common:smallrye-common-os:2.14.0
io.smallrye.common:smallrye-common-ref:2.14.0"
    ;;
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

echo "== run with built-in $ENGINE engine (via [engine] init script) =="
echo "port=$PORT path=$CPATH repo=$REPO engine=$ENGINE"

# 引擎入口脚本：jstart 把解析好的 classpath 写成文件交给脚本，脚本再委托 sas 的
# EmbedCreator（真实容器入口）产出最终命令。init 是文件路径，不是 java 类。
JAVA="$(command -v java)"
cat > "$T/engine-init" <<SH
#!/usr/bin/env bash
set -e
base=""; entry=""; engineCpFile=""; appCpFile=""; entryOut=""; localRepo=""
rest=()
for a in "\$@"; do
  case "\$a" in
    --base=*) base="\${a#*=}" ;;
    --entry=*) entry="\${a#*=}" ;;
    --engine-classpath-file=*) engineCpFile="\${a#*=}" ;;
    --app-classpath-file=*) appCpFile="\${a#*=}" ;;
    --local-repo=*) localRepo="\${a#*=}" ;;
    --entry-out=*) entryOut="\${a#*=}" ;;
    *) rest+=("\$a") ;;
  esac
done
exec "$JAVA" -cp "\$(cat "\$engineCpFile")" org.beangle.sas.engine.$ENGINE.EmbedCreator \\
  --base="\$base" --entry="\$entry" --app-classpath-file="\$appCpFile" \\
  --Dbas.repo="\$localRepo" --entry-out="\$entryOut" "\${rest[@]}"
SH
chmod +x "$T/engine-init"

cat > "$T/app.jstart" <<INI
[app]
entry = $GAV

[engine]
init = $T/engine-init
$ENGINE_DEPS

[args]
--path=$CPATH
INI
"$JSTART" --local="$REPO" run "$T/app.jstart" --port="$PORT" --base="$BASE" >"$LOG" 2>&1 &
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
