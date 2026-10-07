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
sweep() { # sweep <dir>: 记下待清理的组件目录
  local p="$1"
  [ -n "$p" ] || return 0
  DEFAULT_DIRS+=("$p")
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
  out="$("$JSTART" --local="$REPO" --verbose run "$T/app.jar" --base="$T/jar-args" --port=8080 demo)"; code=$?
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

  out="$("$JSTART" --verbose run "$T/nomain.jar" --base="$T/nomain-base" --main=org.jstarttest.Hello 2>&1)"; code=$?
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

  # ===== 一份工件多副本：参数只影响应用，运行目录各自一份
  echo "== per-base extraction =="
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
  outA="$("$JSTART" --quiet --base="$BA" resolve "$SLEEPER")"; codeA=$?
  outB="$("$JSTART" --quiet --base="$BB" resolve "$SLEEPER")"; codeB=$?
  check "copy A resolve" "$codeA" 0 "$BA"
  check "copy B resolve" "$codeB" 0 "$BB"
  # 解压目录按组件目录：<根>/<组件键>/app（每个 base 一份）
  case "$outA" in "$BA"/sleeper-1.0-linux-amd64.tar.gz-*/app/sleeper-1.0/bin/sleeper) ;;
    *) echo "FAIL per-base extraction A: $outA" >&2; failures=$((failures + 1)) ;;
  esac
  case "$outB" in "$BB"/sleeper-1.0-linux-amd64.tar.gz-*/app/sleeper-1.0/bin/sleeper) ;;
    *) echo "FAIL per-base extraction B: $outB" >&2; failures=$((failures + 1)) ;;
  esac
else
  echo "skip native tar.gz test (tar missing)"
fi

echo "== jar app exec (java target) =="
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

  # run 直接 exec java：等 Sleeper 打印 sleeper-up 即证明 exec 成功，再手工结束进程
  "$JSTART" --local="$REPO" --verbose run "$T/sleeper.jar" --base="$T/jar-sleeper" --port=9700 >"$T/jar-run.log" 2>&1 &
  pidJ=$!
  for i in $(seq 1 60); do grep -q "sleeper-up" "$T/jar-run.log" 2>/dev/null && break; sleep 0.5; done
  grep -q "sleeper-up" "$T/jar-run.log" \
    || { echo "FAIL jar app did not start: $(cat "$T/jar-run.log")" >&2; failures=$((failures + 1)); }
  kill "$pidJ" 2>/dev/null || true
  wait "$pidJ" 2>/dev/null || true
else
  echo "skip jar app test (javac/java missing)"
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
  "$JSTART" --local="$REPO" --verbose run "$T/engine.jstart" --port="$warport" --path=/smoke --base="$T/war-base" \
    >"$T/war-run.log" 2>&1 &
  pidW=$!
  # jstart 应 exec init 脚本写出的 argv（Sleeper 启动并打印 sleeper-up）
  for i in $(seq 1 120); do grep -q "sleeper-up" "$T/war-run.log" 2>/dev/null && break; sleep 0.5; done
  grep -q "sleeper-up" "$T/war-run.log" \
    || { echo "FAIL engine argv not exec'd: $(cat "$T/war-run.log")" >&2; failures=$((failures + 1)); }
  ls "$T/war-base"/engine.jstart-*/engine-entry.argv >/dev/null 2>&1 \
    || { echo "FAIL engine-entry.argv not written" >&2; failures=$((failures + 1)); }
  kill "$pidW" 2>/dev/null || true
  wait "$pidW" 2>/dev/null || true
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
  "$JSTART" --local="$REPO" --verbose run "$T/engine-cmd.jstart" --port="$cmdport" --path=/smoke --base="$T/cmd-base" \
    >"$T/war-cmd.log" 2>&1 &
  pidC=$!
  for i in $(seq 1 120); do grep -q "sleeper-up" "$T/war-cmd.log" 2>/dev/null && break; sleep 0.5; done
  grep -q "sleeper-up" "$T/war-cmd.log" \
    || { echo "FAIL init command not exec'd: $(cat "$T/war-cmd.log")" >&2; failures=$((failures + 1)); }
  kill "$pidC" 2>/dev/null || true
  wait "$pidC" 2>/dev/null || true
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
  "$JSTART" --local="$REPO" --verbose run "$T/multi.jstart" --base="$T/multi-base" \
    >"$T/multi-run.log" 2>&1 &
  pidM=$!
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
  kill "$pidM" 2>/dev/null || true
  wait "$pidM" 2>/dev/null || true
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
# resolve 也会解压：输出落在 <base 根>/<name>/app/... 即证明目录名来自 [app] instance
out="$("$JSTART" --quiet resolve "$T/inst.jstart")"; code=$?
check "instance resolve" "$code" 0 "$T/inst-root/named-one"
case "$out" in
  "$T/inst-root/named-one"/app/sleeper-1.0/bin/sleeper) ;;
  *) echo "FAIL instance dir should be <base 根>/<name>: $out" >&2; failures=$((failures + 1)) ;;
esac

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
