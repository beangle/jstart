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

echo
echo "temp dir: $T"
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures check(s)" >&2
  exit 1
fi
echo "all checks passed"
