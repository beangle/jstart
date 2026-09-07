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
  out="$("$JSTART" --local="$REPO" --quiet run "$T/app.jar" --port=8080 demo)"; code=$?
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
printf '%s' "$out" | grep -q -- "--base=$T/sas" || { echo "FAIL war --base layout" >&2; failures=$((failures + 1)); }
[ -f "$T/sas/webapps/demo/WEB-INF/web.xml" ] || { echo "FAIL war exploded layout" >&2; failures=$((failures + 1)); }

echo
echo "temp dir: $T"
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures check(s)" >&2
  exit 1
fi
echo "all checks passed"
