#!/usr/bin/env bash
# jstart smoke test: resolve/classpath/run against a real remote artifact.
# Requires: jstart binary (run `dub build` first), zip, javac/java (optional for run).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JSTART="$ROOT/target/jstart"
if [ ! -x "$JSTART" ]; then
  echo "Cannot find $JSTART, run 'scripts/build_common.sh' (or dub build) first." >&2
  exit 1
fi

T="$(mktemp -d /tmp/jstart-smoke.XXXXXX)"
REPO="$T/repo"
mkdir -p "$T/src/org/jstarttest"
cat > "$T/src/org/jstarttest/Hello.java" <<'JAVA'
package org.jstarttest;
public class Hello {
    public static void main(String[] args) {
        for (String a : args) System.out.println("arg:" + a);
        System.out.println("hello-from-jar");
    }
}
JAVA

failures=0
# 默认根（/var/tmp/jstart）下由本脚本创建的组件目录，成功时一并清理
DEFAULT_DIRS=()
sweep() { # sweep <dir|pid-file>: 记下待清理的目录（组件目录本身）
  local p="$1"
  [ -n "$p" ] || return 0
  case "$p" in */app.pid) p="$(dirname "$p")" ;; esac
  DEFAULT_DIRS+=("$p")
}
proc_gone() { # proc_gone <pid> [seconds]: wait for a stopped process to disappear
  local pid="$1" secs="${2:-5}" i=0
  while [ -d "/proc/$pid" ] && [ "$i" -lt $((secs * 10)) ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ ! -d "/proc/$pid" ]
}

check() { # check <desc> <actual> <expected-exit> <expect-contains>
  local desc="$1" actual="$2" expected="$3" contains="$4"
  if [ "$actual" -ne "$expected" ]; then
    echo "FAIL $desc: exit=$actual expected=$expected" >&2
    failures=$((failures + 1))
    return
  fi
  if [ -n "$contains" ] && ! printf '%s' "$out" | grep -q "$contains"; then
    echo "FAIL $desc: output does not contain '$contains'" >&2
    failures=$((failures + 1))
    return
  fi
  echo "ok   $desc"
}

# build app jar: dependencies file + manifest (no class when javac is absent)
mkdir -p "$T/app/META-INF/beangle"
printf 'org.slf4j:slf4j-api:2.0.17\n' > "$T/app/META-INF/beangle/dependencies"
printf 'Manifest-Version: 1.0\r\nMain-Class: org.jstarttest.Hello\r\n\r\n' > "$T/app/META-INF/MANIFEST.MF"
if command -v javac >/dev/null 2>&1; then
  mkdir -p "$T/classes"
  javac -d "$T/classes" "$T/src/org/jstarttest/Hello.java" && cp -r "$T/classes/." "$T/app/"
fi
(cd "$T/app" && zip -qr "$T/app.jar" .)

echo "== resolve (downloads slf4j-api) =="
out="$("$JSTART" --local="$REPO" --quiet resolve "$T/app.jar")"; code=$?
check "resolve" "$code" 0 "$T/app.jar"

echo "== classpath =="
out="$("$JSTART" --local="$REPO" --quiet classpath "$T/app.jar")"; code=$?
check "classpath main" "$code" 0 "org.jstarttest.Hello@"
check "classpath dep" "$code" 0 "slf4j-api-2.0.17.jar"

echo "== info =="
out="$("$JSTART" --local="$REPO" --quiet info "$T/app.jar")"; code=$?
check "info exit" "$code" 0 "main: org.jstarttest.Hello"
check "info deps" "$code" 0 "deps: 1"
printf '%s' "$out" | grep -q "dep 1: gav org.slf4j:slf4j-api:2.0.17 -> " || { echo "FAIL info dep line" >&2; failures=$((failures + 1)); }

echo "== second resolve uses local cache =="
out="$("$JSTART" --local="$REPO" --quiet resolve "$T/app.jar")"; code=$?
check "resolve cached" "$code" 0 "$T/app.jar"

echo "== run forwards args (needs java + compiled class) =="
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  out="$("$JSTART" --local="$REPO" run "$T/app.jar" --port=8080 demo)"; code=$?
  sweep "$(printf '%s' "$out" | sed -n 's/^Pid file \(.*\) (pid .*/\1/p')"
  check "run exit" "$code" 0 "hello-from-jar"
  printf '%s' "$out" | grep -q "arg:--port=8080" || { echo "FAIL run arg forwarding" >&2; failures=$((failures + 1)); }
  printf '%s' "$out" | grep -q "arg:demo" || { echo "FAIL run arg forwarding" >&2; failures=$((failures + 1)); }
else
  echo "skip run test (javac/java missing)"
fi

echo "== gav target =="
out="$("$JSTART" --local="$REPO" --quiet resolve org.slf4j:slf4j-api:2.0.17)"; code=$?
check "gav resolve" "$code" 0 "slf4j-api-2.0.17.jar"

echo "== war engine --print (downloads engine jars) =="
mkdir -p "$T/war/WEB-INF"
printf '<web-app/>\n' > "$T/war/WEB-INF/web.xml"
(cd "$T/war" && zip -qr "$T/app.war" .)
out="$("$JSTART" --local="$REPO" --quiet run --print "$T/app.war" --port=8080 --path=/demo --base="$T/sas")"; code=$?
check "war print exit" "$code" 0 "org.beangle.sas.engine.tomcat.Bootstrap"
check "war engine jar" "$code" 0 "tomcat-embed-core-11.0.21.jar"
check "war port" "$code" 0 "'--port=8080'"
check "war context" "$code" 0 "'--path=/demo'"
# --base 是根：组件目录 <根>/<组件键> 由 jstart 建，引擎拿到的是组件目录
warBase="$(printf '%s' "$out" | sed -n "s/.*--base=\([^']*\)'.*/\1/p")"
case "$warBase" in
  "$T/sas"/app.war-*) ;;
  *) echo "FAIL war --base layout: $warBase" >&2; failures=$((failures + 1)) ;;
esac
[ -f "$warBase/webapps/demo/WEB-INF/web.xml" ] || { echo "FAIL war exploded layout" >&2; failures=$((failures + 1)); }

# 未显式 --base 时用默认根 /var/tmp/jstart：爆炸到
# <base>/webapps/<ctx>，pid 文件是 <base>/app.pid，一个 base 只跑一个实例
out="$("$JSTART" --local="$REPO" --quiet run --print "$T/app.war" --path=/iso)"; code=$?
check "war default base" "$code" 0 "base=/var/tmp/jstart/"
baseIso="$(printf '%s' "$out" | sed -n "s/.*--base=\([^']*\)'.*/\1/p")"
case "$baseIso" in
  /var/tmp/jstart/app.war-*) ;;
  *) echo "FAIL war default base layout: $baseIso" >&2; failures=$((failures + 1)) ;;
esac
[ -f "$baseIso/webapps/iso/WEB-INF/web.xml" ] \
  || { echo "FAIL war default base explode" >&2; failures=$((failures + 1)); }
[ -n "$baseIso" ] && rm -rf "$baseIso"

echo
if command -v tar >/dev/null 2>&1; then
  echo "== native tar.gz target =="
  mkdir -p "$T/native/demo-1.0/bin" "$T/native/demo-1.0/lib"
  cat > "$T/native/demo-1.0/bin/demo" <<'SH'
#!/bin/sh
for a in "$@"; do echo "arg:$a"; done
echo "hello-from-native"
SH
  chmod +x "$T/native/demo-1.0/bin/demo"
  echo so > "$T/native/demo-1.0/lib/libdemo.so"
  (cd "$T/native" && tar -czf "$T/demo-1.0-linux-amd64.tar.gz" demo-1.0)

  # 组件 base 固定到测试临时目录，路径可预期（native 解压到 <base>/app）
  ND="$T/nativex"

  # resolve：取包 -> 解压到 <base>/app（base = <根>/<组件键>）-> 输出可执行文件路径
  out="$("$JSTART" --quiet --base="$ND" resolve "$T/demo-1.0-linux-amd64.tar.gz")"; code=$?
  check "native resolve" "$code" 0 "/app/demo-1.0/bin/demo"
  case "$out" in
    "$ND"/demo-1.0-linux-amd64.tar.gz-*/app/demo-1.0/bin/demo) ;;
    *) echo "FAIL native resolve layout: $out" >&2; failures=$((failures + 1)) ;;
  esac

  # --print：参数按序跟在可执行文件之后
  out="$("$JSTART" --quiet --base="$ND" run --print "$T/demo-1.0-linux-amd64.tar.gz" --port=8080 extra)"; code=$?
  check "native print" "$code" 0 "'--port=8080' 'extra'"

  # run：直接 exec 解压出的可执行文件，参数原样透传
  out="$("$JSTART" --quiet --base="$ND" run "$T/demo-1.0-linux-amd64.tar.gz" --port=8080 extra)"; code=$?
  check "native run" "$code" 0 "hello-from-native"
  check "native arg" "$code" 0 "arg:--port=8080"

  # 默认 base：/var/tmp/jstart/<组件键>/app（不用包旁目录兜底）
  out="$("$JSTART" --quiet resolve "$T/demo-1.0-linux-amd64.tar.gz")"; code=$?
  check "native default resolve" "$code" 0 "demo-1.0/bin/demo"
  case "$out" in
    /var/tmp/jstart/demo-1.0-linux-amd64.tar.gz-*/app/demo-1.0/bin/demo) ;;
    *) echo "FAIL native default dir: unexpected $out" >&2; failures=$((failures + 1)) ;;
  esac
  sweep "$(dirname "$(dirname "$(dirname "$(dirname "$out")")")")"
  rm -rf "$(dirname "$(dirname "$(dirname "$out")")")"

  # fetch 也接受本地文件（原样返回绝对路径）；http(s) url 则下载到本地仓库
  out="$("$JSTART" --quiet fetch "$T/demo-1.0-linux-amd64.tar.gz")"; code=$?
  check "fetch local file" "$code" 0 "$T/demo-1.0-linux-amd64.tar.gz"

  # launch spec：entry 指向 tar.gz，[app] exec 指定包内可执行文件，[args] 附加参数
  cat > "$T/native.jstart" <<EOF
[app]
entry = $T/demo-1.0-linux-amd64.tar.gz
exec = demo-1.0/bin/demo

[args]
--from-spec=1
EOF
  out="$("$JSTART" --quiet --base="$ND" run "$T/native.jstart" --cli=2)"; code=$?
  check "native spec run" "$code" 0 "arg:--from-spec=1"
  check "native spec cli arg" "$code" 0 "arg:--cli=2"

  # 另一个 --base：解压到该 base 下的 app/，而不是包旁
  out="$("$JSTART" --quiet --base="$T/nativey" run "$T/demo-1.0-linux-amd64.tar.gz" --port=1)"; code=$?
  check "native --base run" "$code" 0 "hello-from-native"
  ls "$T/nativey"/*/app/demo-1.0/bin/demo >/dev/null 2>&1 \
    || { echo "FAIL base layout" >&2; failures=$((failures + 1)); }
  [ ! -e "$T/demo-1.0-linux-amd64" ] \
    || { echo "FAIL extraction must not land beside the archive" >&2; failures=$((failures + 1)); }

  # ===== pid/stop：一份工件多副本（参数区分），解压目录共用、运行目录各自一份
  echo "== pid file / stop =="
  mkdir -p "$T/sleeper/sleeper-1.0/bin"
  cat > "$T/sleeper/sleeper-1.0/bin/sleeper" <<'SH'
#!/bin/sh
trap 'exit 0' TERM
while true; do sleep 1; done
SH
  chmod +x "$T/sleeper/sleeper-1.0/bin/sleeper"
  (cd "$T/sleeper" && tar -czf "$T/sleeper-1.0-linux-amd64.tar.gz" sleeper-1.0)

  SLEEPER="$T/sleeper-1.0-linux-amd64.tar.gz"
  BA="$T/inst-a"
  BB="$T/inst-b"
  # 一个组件多副本：各给一个 base（参数只影响应用，不参与实例身份）
  "$JSTART" run "$SLEEPER" --base="$BA" --port=8081 >"$T/inst-a.log" 2>&1 &
  "$JSTART" run "$SLEEPER" --base="$BB" --port=8082 --path=/b >"$T/inst-b.log" 2>&1 &
  sleep 3
  pidA="$(sed -n 's/.*(pid \([0-9]*\)).*/\1/p' "$T/inst-a.log")"
  pidB="$(sed -n 's/.*(pid \([0-9]*\)).*/\1/p' "$T/inst-b.log")"
  [ -n "$pidA" ] && [ -n "$pidB" ] && [ "$pidA" != "$pidB" ] \
    || { echo "FAIL instance pids: A=$pidA B=$pidB" >&2; failures=$((failures + 1)); }
  # 解压目录按组件目录：<根>/<组件键>/app（每个 base 一份）
  extractA="$(sed -n 's#^Running \(.*\)/sleeper-1.0/bin/sleeper .*#\1#p' "$T/inst-a.log")"
  extractB="$(sed -n 's#^Running \(.*\)/sleeper-1.0/bin/sleeper .*#\1#p' "$T/inst-b.log")"
  case "$extractA" in "$BA"/sleeper-1.0-linux-amd64.tar.gz-*/app) ;; *) extractA="" ;; esac
  case "$extractB" in "$BB"/sleeper-1.0-linux-amd64.tar.gz-*/app) ;; *) extractB="" ;; esac
  [ -n "$extractA" ] && [ -n "$extractB" ] \
    || { echo "FAIL per-base extraction dir: A=$extractA B=$extractB" >&2; failures=$((failures + 1)); }
  # pid 文件固定在 <base>/app.pid
  pidPathA="$(sed -n 's/^Pid file \(.*\) (pid .*/\1/p' "$T/inst-a.log")"
  pidPathB="$(sed -n 's/^Pid file \(.*\) (pid .*/\1/p' "$T/inst-b.log")"
  case "$pidPathA" in "$BA"/sleeper-1.0-linux-amd64.tar.gz-*/app.pid) ;; *) pidPathA="" ;; esac
  case "$pidPathB" in "$BB"/sleeper-1.0-linux-amd64.tar.gz-*/app.pid) ;; *) pidPathB="" ;; esac
  [ -n "$pidPathA" ] && [ -n "$pidPathB" ] \
    || { echo "FAIL pid file layout: A=$pidPathA B=$pidPathB" >&2; failures=$((failures + 1)); }
  # 同一个 base 再启动就被拒（参数不同也一样：参数不参与身份）
  out="$("$JSTART" run "$SLEEPER" --base="$BA" --port=9999 2>&1)"; code=$?
  check "duplicate base refused" "$code" 1 "Already running"
  # 没用 --base 启动的默认 base 没在跑：stop 报未运行（顺手记下这个空目录）
  out="$("$JSTART" stop "$SLEEPER" 2>&1)"; code=$?
  check "stop other base is a no-op" "$code" 3 "nothing to stop"
  sweep "$(printf '%s' "$out" | sed -n 's/^No pid file \(.*\): nothing to stop.*/\1/p')"
  # stop 只认 base：应用参数被忽略，多给也不影响
  out="$("$JSTART" stop "$SLEEPER" --base="$BB" --port=8082 --path=/b 2>&1)"; code=$?
  check "stop ignores args" "$code" 0 "Stopped pid"
  out="$("$JSTART" stop "$SLEEPER" --base="$BA" 2>&1)"; code=$?
  check "stop instance A" "$code" 0 "Stopped pid"
  proc_gone "$pidA" || { echo "FAIL pid A still alive" >&2; failures=$((failures + 1)); }
  proc_gone "$pidB" || { echo "FAIL pid B still alive" >&2; failures=$((failures + 1)); }
  # 停止后 pid 文件消失，解压目录保留（下次启动直接复用）
  [ -e "$pidPathA" ] && { echo "FAIL stale pid file $pidPathA" >&2; failures=$((failures + 1)); }
  ls "$BA"/*/app/sleeper-1.0/bin/sleeper >/dev/null 2>&1 \
    || { echo "FAIL extraction dir should survive stop" >&2; failures=$((failures + 1)); }
  out="$("$JSTART" stop "$SLEEPER" --base="$BA" 2>&1)"; code=$?
  check "second stop is a no-op" "$code" 3 "nothing to stop"
else
  echo "skip native tar.gz test (tar missing)"
fi

echo "== pid/stop for jar (java target) =="
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  cat > "$T/src/org/jstarttest/Sleeper.java" <<'JAVA'
package org.jstarttest;
public class Sleeper {
    public static void main(String[] args) throws Exception {
        System.out.println("sleeper-up");
        while (true) { Thread.sleep(1000); }
    }
}
JAVA
  mkdir -p "$T/sleeper-classes/META-INF"
  javac -d "$T/sleeper-classes" "$T/src/org/jstarttest/Sleeper.java"
  printf 'Manifest-Version: 1.0\r\nMain-Class: org.jstarttest.Sleeper\r\n\r\n' \
    > "$T/sleeper-classes/META-INF/MANIFEST.MF"
  (cd "$T/sleeper-classes" && zip -qr "$T/sleeper.jar" .)

  "$JSTART" --local="$REPO" run "$T/sleeper.jar" --port=9700 >"$T/jar-run.log" 2>&1 &
  for i in $(seq 1 60); do grep -q "Pid file" "$T/jar-run.log" 2>/dev/null && break; sleep 1; done
  pidJ="$(sed -n 's/.*(pid \([0-9]*\)).*/\1/p' "$T/jar-run.log")"
  pidPathJ="$(sed -n 's/^Pid file \(.*\) (pid .*/\1/p' "$T/jar-run.log")"
  [ -n "$pidJ" ] || { echo "FAIL jar pid not recorded: $(cat "$T/jar-run.log")" >&2; failures=$((failures + 1)); }
  case "$pidPathJ" in
    /var/tmp/jstart/sleeper.jar-*/app.pid) ;;
    *) echo "FAIL jar base layout: $pidPathJ" >&2; failures=$((failures + 1)) ;;
  esac
  out="$("$JSTART" --local="$REPO" stop "$T/sleeper.jar" 2>&1)"; code=$?
  check "stop jar app" "$code" 0 "Stopped pid"
  proc_gone "$pidJ" || { echo "FAIL jar pid still alive" >&2; failures=$((failures + 1)); }
  [ -e "$pidPathJ" ] && { echo "FAIL jar pid file left" >&2; failures=$((failures + 1)); }
else
  echo "skip jar stop test (javac/java missing)"
fi

echo "== pid/stop for war (tomcat engine) =="
if command -v java >/dev/null 2>&1; then
  warport=$((20000 + RANDOM % 10000))
  "$JSTART" --local="$REPO" run "$T/app.war" --port="$warport" --path=/smoke --base="$T/sas-stop" \
    >"$T/war-run.log" 2>&1 &
  for i in $(seq 1 120); do grep -q "Pid file" "$T/war-run.log" 2>/dev/null && break; sleep 1; done
  pidW="$(sed -n 's/.*(pid \([0-9]*\)).*/\1/p' "$T/war-run.log")"
  [ -n "$pidW" ] || { echo "FAIL war pid not recorded" >&2; failures=$((failures + 1)); }
  # stop 只要 base，不需要 run 时的 --port/--path
  out="$("$JSTART" --local="$REPO" stop "$T/app.war" --base="$T/sas-stop" 2>&1)"; code=$?
  check "stop war app" "$code" 0 "Stopped pid"
  proc_gone "$pidW" || { echo "FAIL war pid still alive" >&2; failures=$((failures + 1)); }
else
  echo "skip war stop test (java missing)"
fi

echo
if [ "$failures" -gt 0 ]; then
  echo "temp dir: $T" >&2
  if [ ${#DEFAULT_DIRS[@]} -gt 0 ]; then
    printf 'left in default root: %s\n' "${DEFAULT_DIRS[*]}" >&2
  fi
  echo "FAILED: $failures check(s)" >&2
  exit 1
fi
# 成功即回收：脚本在默认根下建的组件目录与整个临时目录
for d in "${DEFAULT_DIRS[@]}"; do rm -rf "$d"; done
rm -rf "$T"
echo "all checks passed"
