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
# fake engine init 脚本用 $JAVA 拼最终命令；导出后由 jstart exec 子进程继承
JAVA="$(command -v java 2>/dev/null || true)"
export JAVA

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
  if [ -n "$contains" ] && ! printf '%s' "$out" | grep -q -e "$contains"; then
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

echo "== [libs]: 追加/覆盖，同名 g:a 与内置清单去重 =="
# app.jar 的清单已含 slf4j-api:2.0.17；spec 再声明同名 [libs] 后合并结果仍应只有 1 条。
cat > "$T/libs.jstart" <<INI
[app]
main = org.jstarttest.Hello
entry = $T/app.jar

[libs]
org.slf4j:slf4j-api:2.0.17
INI
out="$("$JSTART" --local="$REPO" --quiet info "$T/libs.jstart")"; code=$?
check "libs merge info" "$code" 0 "libs: 1"
check "libs merge dedup" "$code" 0 "deps: 1"
out="$("$JSTART" --local="$REPO" --quiet classpath "$T/libs.jstart")"; code=$?
check "libs merge classpath" "$code" 0 "slf4j-api-2.0.17.jar"
# 旧名 [deps] 仍可用：告警提示改名，行为等同 [libs]。
cat > "$T/deps-alias.jstart" <<INI
[app]
main = org.jstarttest.Hello
entry = $T/app.jar

[deps]
org.slf4j:slf4j-api:2.0.17
INI
out="$("$JSTART" --local="$REPO" info "$T/deps-alias.jstart" 2>&1)"; code=$?
check "deps alias warns" "$code" 0 "改名为"
printf '%s' "$out" | grep -q "已改名为 \[libs\]" \
  || { echo "FAIL deps alias warning text: $out" >&2; failures=$((failures + 1)); }
check "deps alias merges" "$code" 0 "deps: 1"

echo "== run forwards args (needs java + compiled class) =="
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  out="$("$JSTART" --local="$REPO" --verbose run "$T/app.jar" --port=8080 demo)"; code=$?
  sweep "$(printf '%s' "$out" | sed -n 's/^Pid file \(.*\) (pid .*/\1/p')"
  check "run exit" "$code" 0 "hello-from-jar"
  printf '%s' "$out" | grep -q "arg:--port=8080" || { echo "FAIL run arg forwarding" >&2; failures=$((failures + 1)); }
  printf '%s' "$out" | grep -q "arg:demo" || { echo "FAIL run arg forwarding" >&2; failures=$((failures + 1)); }
else
  echo "skip run test (javac/java missing)"
fi

echo "== custom main class (--main) =="
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  # 没有 Main-Class 的 jar：主类只能靠 --main 指定（解压目录同理）
  mkdir -p "$T/nomain/META-INF"
  printf 'Manifest-Version: 1.0\r\n\r\n' > "$T/nomain/META-INF/MANIFEST.MF"
  cp -r "$T/classes/." "$T/nomain/"
  (cd "$T/nomain" && zip -qr "$T/nomain.jar" .)

  out="$("$JSTART" --verbose run "$T/nomain.jar" --main=org.jstarttest.Hello 2>&1)"; code=$?
  sweep "$(printf '%s' "$out" | sed -n 's/^Pid file \(.*\) (pid .*/\1/p')"
  check "run --main" "$code" 0 "hello-from-jar"
  out="$("$JSTART" --quiet run "$T/nomain.jar" 2>&1)"; code=$?
  check "no main is an error" "$code" 1 "Pass --main=<class>"

  # --main 优先于 manifest，并同步反映在 classpath/info
  out="$("$JSTART" --quiet --main=org.jstarttest.Hello classpath "$T/nomain.jar")"; code=$?
  check "classpath --main" "$code" 0 "org.jstarttest.Hello@"
  out="$("$JSTART" --quiet --main=org.jstarttest.Hello info "$T/nomain.jar")"; code=$?
  check "info main source" "$code" 0 "main source: cli"
  out="$("$JSTART" --quiet info "$T/nomain.jar")"; code=$?
  check "info main none" "$code" 0 "main source: none"
  # 启动模型由解析结果推导：jar 是 app（entry type 才是构件形态）。
  check "info app type" "$code" 0 "type: app"
  printf '%s' "$out" | grep -q "^entry type: jar$" \
    || { echo "FAIL info missing entry type: $out" >&2; failures=$((failures + 1)); }

  # 空值/非法值立刻报错（--main 由 jstart 消费，不转发给应用）
  out="$("$JSTART" --quiet run "$T/app.jar" --main= 2>&1)"; code=$?
  check "empty --main rejected" "$code" 2 "Invalid --main value"
  out="$("$JSTART" --quiet run "$T/app.jar" --main=/tmp/App.java 2>&1)"; code=$?
  check "path --main rejected" "$code" 2 "Invalid --main value"
else
  echo "skip --main test (javac/java missing)"
fi

echo "== gav target =="
out="$("$JSTART" --local="$REPO" --quiet resolve org.slf4j:slf4j-api:2.0.17)"; code=$?
check "gav resolve" "$code" 0 "slf4j-api-2.0.17.jar"

echo "== war engine (spec-only; [engine] 用本地文件，不联网) =="
mkdir -p "$T/war/WEB-INF"
printf '<web-app/>\n' > "$T/war/WEB-INF/web.xml"
(cd "$T/war" && zip -qr "$T/app.war" .)
# run 不再直接吃 war：必须先写 launch spec（[app] entry + [engine] init）
out="$("$JSTART" --local="$REPO" --quiet run --print "$T/app.war" --port=8080 2>&1)"; code=$?
check "bare war run rejected" "$code" 1 "must run through a launch spec"

# 引擎 jar 用本地空文件即可（--print 走完解析但不执行脚本）
mkdir -p "$T/engine"
: > "$T/engine/beangle-bas-engine-0.13.17.jar"
: > "$T/engine/tomcat-embed-core-11.0.21.jar"

# [app] main 与 [engine] 段互斥：spec 里同时写 main 和 [engine] init 直接报错
cat > "$T/bad.jstart" <<INI
[app]
entry = $T/app.war
main = org.example.Main

[engine]
init = $T/engine/init.sh
INI
out="$("$JSTART" --local="$REPO" --quiet run --print "$T/bad.jstart" 2>&1)"; code=$?
check "main+engine rejected" "$code" 1 "mutually exclusive"

# [app] engine 已移除：告警提示改用 [engine] init（不再是引擎声明）
cat > "$T/oldkey.jstart" <<INI
[app]
entry = $T/app.war
engine = tomcat
INI
out="$("$JSTART" --local="$REPO" run --print "$T/oldkey.jstart" 2>&1)"; code=$?
check "[app] engine removed" "$code" 1 "已移除"

# war 必须显式声明引擎：jstart 无内置引擎目录，也不从 .war 后缀反推
cat > "$T/noengine.jstart" <<INI
[app]
entry = $T/app.war
INI
out="$("$JSTART" --local="$REPO" --quiet run --print "$T/noengine.jstart" 2>&1)"; code=$?
check "war needs engine" "$code" 1 "init = <script>"

cat > "$T/nodeps.jstart" <<INI
[app]
entry = $T/app.war

[engine]
$T/engine/tomcat-embed-core-11.0.21.jar
INI
out="$("$JSTART" --local="$REPO" --quiet run --print "$T/nodeps.jstart" 2>&1)"; code=$?
check "engine needs init" "$code" 1 "needs an init command"

# --print 只打印引擎准备命令，不真的运行 init 脚本
cat > "$T/app.jstart" <<INI
[app]
entry = $T/app.war

[engine]
init = $T/engine/init.sh
$T/engine/beangle-bas-engine-0.13.17.jar
$T/engine/tomcat-embed-core-11.0.21.jar

[args]
--path=/demo
INI
out="$("$JSTART" --local="$REPO" --main=org.example.Ignored run --print "$T/app.jstart" --port=8080 --base="$T/bas" 2>&1)"; code=$?
check "war print exit" "$code" 0 "$T/engine/init.sh"
check "war entry" "$code" 0 "--entry=$T/app.war"
check "war engine classpath" "$code" 0 "--engine-classpath-file="
check "war app classpath" "$code" 0 "--app-classpath-file="
check "war local repo" "$code" 0 "--local-repo="
check "war port" "$code" 0 "'--port=8080'"
check "war context" "$code" 0 "'--path=/demo'"
check "war ignores --main" "$code" 0 "ignored for engine targets"
# --base 是根：组件目录 <根>/<组件键> 由 jstart 建（spec 目标的组件键取 spec 文件名）
# jstart 不再自己爆炸 war：docBase 布局与爆炸都归引擎 init 脚本（见 docs/engine.md）
warBase="$(printf '%s' "$out" | sed -n "s/.*--base=\([^']*\)'.*/\1/p")"
case "$warBase" in
  "$T/bas"/app.jstart-*) ;;
  *) echo "FAIL war --base layout: $warBase" >&2; failures=$((failures + 1)) ;;
esac

# 未显式 --base 时用默认根 /var/tmp/jstart（组件目录 <根>/<组件键>）
out="$("$JSTART" --local="$REPO" --quiet run --print "$T/app.jstart" --path=/iso)"; code=$?
check "war default base" "$code" 0 "base=/var/tmp/jstart/"
baseIso="$(printf '%s' "$out" | sed -n "s/.*--base=\([^']*\)'.*/\1/p")"
case "$baseIso" in
  /var/tmp/jstart/app.jstart-*) ;;
  *) echo "FAIL war default base layout: $baseIso" >&2; failures=$((failures + 1)) ;;
esac
[ -n "$baseIso" ] && sweep "$baseIso"

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
  "$JSTART" --verbose run "$SLEEPER" --base="$BA" --port=8081 >"$T/inst-a.log" 2>&1 &
  "$JSTART" --verbose run "$SLEEPER" --base="$BB" --port=8082 --path=/b >"$T/inst-b.log" 2>&1 &
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

  "$JSTART" --local="$REPO" --verbose run "$T/sleeper.jar" --port=9700 >"$T/jar-run.log" 2>&1 &
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

echo "== war engine end-to-end: init -> entry-out argv -> exec =="
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  # 一个最小引擎 init 脚本：读 jstart 写好的 classpath 文件，把最终 argv（NUL 分隔）
  # 写到 --entry-out，jstart 再 exec 它。覆盖完整协议：准备 -> entry-out -> exec
  # （不依赖真实 bas）。
  mkdir -p "$T/fakeengine/META-INF"
  javac -d "$T/fakeengine" "$T/src/org/jstarttest/Sleeper.java"
  (cd "$T/fakeengine" && zip -qr "$T/fake-engine.jar" .)
  cat > "$T/fake-engine-init" <<'SH'
#!/usr/bin/env bash
set -e
entryOut=""; engineCpFile=""; appCpFile=""
for a in "$@"; do
  case "$a" in
    --entry-out=*) entryOut="${a#*=}" ;;
    --engine-classpath-file=*) engineCpFile="${a#*=}" ;;
    --app-classpath-file=*) appCpFile="${a#*=}" ;;
  esac
done
cp="$(cat "$engineCpFile")"
if [ -s "$appCpFile" ]; then cp="$cp:$(cat "$appCpFile")"; fi
printf '%s\0' "$JAVA" -cp "$cp" org.jstarttest.Sleeper > "$entryOut"
SH
  chmod +x "$T/fake-engine-init"

  cat > "$T/engine.jstart" <<INI
[app]
entry = $T/app.war

[engine]
init = $T/fake-engine-init
$T/fake-engine.jar
INI
  warport=$((20000 + RANDOM % 10000))
  "$JSTART" --local="$REPO" --verbose run "$T/engine.jstart" --port="$warport" --path=/smoke --base="$T/bas-stop" \
    >"$T/war-run.log" 2>&1 &
  for i in $(seq 1 120); do grep -q "Pid file" "$T/war-run.log" 2>/dev/null && break; sleep 1; done
  pidW="$(sed -n 's/.*(pid \([0-9]*\)).*/\1/p' "$T/war-run.log")"
  [ -n "$pidW" ] || { echo "FAIL war pid not recorded" >&2; failures=$((failures + 1)); }
  # jstart 应 exec init 脚本写出的 argv（Sleeper 启动并打印 sleeper-up）
  for i in $(seq 1 60); do grep -q "sleeper-up" "$T/war-run.log" 2>/dev/null && break; sleep 0.5; done
  grep -q "sleeper-up" "$T/war-run.log" \
    || { echo "FAIL engine argv not exec'd: $(cat "$T/war-run.log")" >&2; failures=$((failures + 1)); }
  ls "$T/bas-stop"/engine.jstart-*/engine-entry.argv >/dev/null 2>&1 \
    || { echo "FAIL engine-entry.argv not written" >&2; failures=$((failures + 1)); }
  # stop 只要 base，不需要 run 时的 --port/--path
  out="$("$JSTART" --local="$REPO" stop "$T/engine.jstart" --base="$T/bas-stop" 2>&1)"; code=$?
  check "stop war app" "$code" 0 "Stopped pid"
  proc_gone "$pidW" || { echo "FAIL war pid still alive" >&2; failures=$((failures + 1)); }
else
  echo "skip war engine test (javac/java missing)"
fi

echo "== [engine] init command form: program + args, no executable wrapper =="
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  # 同一份引擎逻辑，但去掉可执行位，直接以命令行声明 `init = bash <脚本>`：
  # 证明 init 支持「程序 + 参数」，不必再准备一个可执行的 wrapper 文件。
  cp "$T/fake-engine-init" "$T/fake-engine-cmd.sh"
  chmod -x "$T/fake-engine-cmd.sh"
  cat > "$T/engine-cmd.jstart" <<INI
[app]
entry = $T/app.war

[engine]
init = bash $T/fake-engine-cmd.sh
$T/fake-engine.jar
INI
  cmdport=$((20000 + RANDOM % 10000))
  "$JSTART" --local="$REPO" --verbose run "$T/engine-cmd.jstart" --port="$cmdport" --path=/smoke --base="$T/bas-cmd" \
    >"$T/war-cmd.log" 2>&1 &
  for i in $(seq 1 120); do grep -q "Pid file" "$T/war-cmd.log" 2>/dev/null && break; sleep 1; done
  pidC="$(sed -n 's/.*(pid \([0-9]*\)).*/\1/p' "$T/war-cmd.log")"
  [ -n "$pidC" ] || { echo "FAIL command-form pid not recorded" >&2; failures=$((failures + 1)); }
  for i in $(seq 1 60); do grep -q "sleeper-up" "$T/war-cmd.log" 2>/dev/null && break; sleep 0.5; done
  grep -q "sleeper-up" "$T/war-cmd.log" \
    || { echo "FAIL init command not exec'd: $(cat "$T/war-cmd.log")" >&2; failures=$((failures + 1)); }
  out="$("$JSTART" --local="$REPO" stop "$T/engine-cmd.jstart" --base="$T/bas-cmd" 2>&1)"; code=$?
  check "stop command-form init" "$code" 0 "Stopped pid"
  proc_gone "$pidC" || { echo "FAIL command-form pid still alive" >&2; failures=$((failures + 1)); }
else
  echo "skip init command-form test (javac/java missing)"
fi

echo "== multi-webapp spec: [subapp] -> <base>/engine-subapps.jstart -> dist engine -> entry-out =="
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  # 一个假的 dist 引擎 init 脚本：按 --base 约定读 <base>/engine-subapps.jstart（launch
  # spec 片段），校验 [subapp <id>] 段数、每段的 entry/path 是否完整、entry 是否真实存在、
  # libs 是否带过来，再 exec 一个回显计划文件的短程序（不依赖真实 bas，也不经命令行传计划）。
  cat > "$T/src/org/jstarttest/PlanEcho.java" <<'JAVA'
package org.jstarttest;
import java.nio.file.Files;
import java.nio.file.Paths;
public class PlanEcho {
    public static void main(String[] args) throws Exception {
        System.out.println("plan-up");
        for (String l : Files.readAllLines(Paths.get(args[0]))) System.out.println("row:" + l);
        while (true) { Thread.sleep(1000); }
    }
}
JAVA
  cat > "$T/fake-dist-init" <<'SH'
#!/usr/bin/env bash
set -e
base=""; entryOut=""; engineCpFile=""
for a in "$@"; do
  case "$a" in
    --base=*) base="${a#*=}" ;;
    --entry-out=*) entryOut="${a#*=}" ;;
    --engine-classpath-file=*) engineCpFile="${a#*=}" ;;
  esac
done
plan="$base/engine-subapps.jstart"
[ -f "$plan" ] || { echo "missing plan $plan" >&2; exit 1; }
apps="$(grep -c '^\[subapp ' "$plan")"
[ "$apps" = 2 ] || { echo "expected 2 subapps, got $apps" >&2; exit 1; }
grep -q '^libs = org.slf4j:slf4j-api:2.0.17' "$plan" \
  || { echo "portal libs missing from plan" >&2; exit 1; }
grep -q '/portal' "$plan" || { echo "portal path missing" >&2; exit 1; }
grep -q '/admin' "$plan" || { echo "admin path missing" >&2; exit 1; }
while IFS= read -r l; do
  case "$l" in
    entry*=*) f="${l#entry = }"; [ -f "$f" ] || { echo "missing entry $f" >&2; exit 1; } ;;
  esac
done < "$plan"
cp="$(cat "$engineCpFile")"
printf '%s\0' "$JAVA" -cp "$cp" org.jstarttest.PlanEcho "$plan" > "$entryOut"
SH
  chmod +x "$T/fake-dist-init"
  javac -d "$T/fakedist" "$T/src/org/jstarttest/PlanEcho.java"
  (cd "$T/fakedist" && zip -qr "$T/fake-dist.jar" .)

  mkdir -p "$T/multi-a/WEB-INF/classes" "$T/multi-b/WEB-INF/classes"
  echo portal > "$T/multi-a/WEB-INF/classes/marker.txt"
  echo admin > "$T/multi-b/WEB-INF/classes/marker.txt"
  # portal 的 war 清单故意写一个取不到的 slf4j 版本；spec 用 libs 覆盖成同 g:a 的
  # 可用版本后，jstart 只应取 libs 版本（旧的被丢弃、不再需要下载）。
  mkdir -p "$T/multi-a/WEB-INF/classes/META-INF/beangle"
  printf 'org.slf4j:slf4j-api:0.0.1-nonexistent\n' \
    > "$T/multi-a/WEB-INF/classes/META-INF/beangle/dependencies"
  (cd "$T/multi-a" && zip -qr "$T/portal.war" .)
  (cd "$T/multi-b" && zip -qr "$T/admin.war" .)

  cat > "$T/multi.jstart" <<INI
[engine]
init = $T/fake-dist-init
$T/fake-dist.jar

[subapp portal]
entry = $T/portal.war
path = /portal
libs = org.slf4j:slf4j-api:2.0.17

[subapp admin]
entry = $T/admin.war
path = /admin
INI
  "$JSTART" --local="$REPO" --verbose run "$T/multi.jstart" --base="$T/multi-stop" \
    >"$T/multi-run.log" 2>&1 &
  for i in $(seq 1 120); do grep -q "plan-up" "$T/multi-run.log" 2>/dev/null && break; sleep 0.5; done
  grep -q "plan-up" "$T/multi-run.log" \
    || { echo "FAIL multi-webapp engine argv not exec'd: $(cat "$T/multi-run.log")" >&2; failures=$((failures + 1)); }
  grep -q "row:\[subapp portal\]" "$T/multi-run.log" \
    || { echo "FAIL portal plan row missing: $(cat "$T/multi-run.log")" >&2; failures=$((failures + 1)); }
  grep -q "row:\[subapp admin\]" "$T/multi-run.log" \
    || { echo "FAIL admin plan row missing: $(cat "$T/multi-run.log")" >&2; failures=$((failures + 1)); }
  grep -q "row:libs = org.slf4j:slf4j-api:2.0.17" "$T/multi-run.log" \
    || { echo "FAIL portal libs missing from plan" >&2; failures=$((failures + 1)); }
  grep -q "/portal" "$T/multi-run.log" \
    || { echo "FAIL portal context path missing" >&2; failures=$((failures + 1)); }
  grep -q "/admin" "$T/multi-run.log" \
    || { echo "FAIL admin context path missing" >&2; failures=$((failures + 1)); }
  pidM="$(sed -n 's/.*(pid \([0-9]*\)).*/\1/p' "$T/multi-run.log")"
  [ -n "$pidM" ] || { echo "FAIL multi-webapp pid not recorded" >&2; failures=$((failures + 1)); }
  # resolve/info 按 webapp 逐个给出；classpath 对多应用无意义，明确拒绝
  out="$("$JSTART" --local="$REPO" resolve "$T/multi.jstart" 2>&1)"; code=$?
  check "resolve multi-webapp" "$code" 0 "portal.war"
  printf '%s' "$out" | grep -q "admin.war" \
    || { echo "FAIL resolve missing admin entry: $out" >&2; failures=$((failures + 1)); }
  out="$("$JSTART" --local="$REPO" info "$T/multi.jstart" 2>&1)"; code=$?
  check "info multi-webapp" "$code" 0 "type: engine"
  printf '%s' "$out" | grep -q "path=/admin" \
    || { echo "FAIL info missing admin path: $out" >&2; failures=$((failures + 1)); }
  printf '%s' "$out" | grep -q "libs=1" \
    || { echo "FAIL info missing portal libs count: $out" >&2; failures=$((failures + 1)); }
  # 覆盖规则：portal 的 war 清单版本被 libs 覆盖，info 只应列出 libs 的版本。
  printf '%s' "$out" | grep -q "slf4j-api-2.0.17.jar" \
    || { echo "FAIL info missing portal lib jar: $out" >&2; failures=$((failures + 1)); }
  if printf '%s' "$out" | grep -q "0.0.1-nonexistent"; then
    echo "FAIL info still lists overridden war dep: $out" >&2; failures=$((failures + 1))
  fi
  out="$("$JSTART" --local="$REPO" classpath "$T/multi.jstart" 2>&1)"; code=$?
  check "classpath multi-webapp rejected" "$code" 2 "not supported"
  # 多应用必须声明 [engine] init：缺 [engine] 段在校验阶段被拒
  cat > "$T/multi-bad.jstart" <<INI
[subapp a]
entry = $T/portal.war
path = /a
INI
  out="$("$JSTART" --local="$REPO" run "$T/multi-bad.jstart" --base="$T/multi-bad" 2>&1)"; code=$?
  check "multi-webapp needs engine" "$code" 1 "ships no built-in engine"
  # stop 只需 base
  out="$("$JSTART" --local="$REPO" stop "$T/multi.jstart" --base="$T/multi-stop" 2>&1)"; code=$?
  check "stop multi-webapp" "$code" 0 "Stopped pid"
  proc_gone "$pidM" || { echo "FAIL multi-webapp pid still alive" >&2; failures=$((failures + 1)); }
else
  echo "skip multi-webapp test (javac/java missing)"
fi

# ===== [app] instance：spec-only 的显式组件目录名（<base 根>/<name>，不拼指纹）
echo "== [app] instance =="
cat > "$T/inst.jstart" <<INI
[app]
entry = $SLEEPER
base = $T/inst-root
instance = named-one
INI
"$JSTART" --verbose run "$T/inst.jstart" --port=8085 >"$T/inst.log" 2>&1 &
sleep 3
pidN="$(sed -n 's/.*(pid \([0-9]*\)).*/\1/p' "$T/inst.log")"
[ -n "$pidN" ] || { echo "FAIL instance spec start" >&2; failures=$((failures + 1)); }
[ -f "$T/inst-root/named-one/app.pid" ] \
  || { echo "FAIL instance dir should be <base 根>/<name>" >&2; failures=$((failures + 1)); }
# instance 只在 spec 里：spec 读不到时 stop 明确提示并回退（不是静默跳过）
out="$("$JSTART" stop "$T/inst-missing.jstart" 2>&1)"; code=$?
check "stop without readable spec hints instance" "$code" 3 "cannot read launch spec"
sweep "$(printf '%s' "$out" | sed -n 's/^No pid file \(.*\): nothing to stop.*/\1/p')"
out="$("$JSTART" stop "$T/inst.jstart" 2>&1)"; code=$?
check "stop instance spec" "$code" 0 "Stopped pid"
proc_gone "$pidN" || { echo "FAIL instance pid still alive" >&2; failures=$((failures + 1)); }

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
