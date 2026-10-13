# jstart

A lightweight launcher for Java artifacts, written in D: it exposes an app (jar/war, or a
GraalVM native `tar.gz`), downloads the missing Maven dependencies, prepares the runtime
environment, and `exec`s into `java` (or the extracted native executable).

jstart is a self-contained native binary meant to be used as a **command**, not a daemon.

## Features

- Targets: local jar, exploded war directory, `g:a:v` / `gav://`, `http(s)://` url, and
  launch specs (`.jstart`, local path or remote url). A war can only be started through a
  launch spec, declared as `[app] entry`.
- Reads the dependency manifest bundled in the app (jar: `META-INF/beangle/dependencies`;
  war: `WEB-INF/classes/...`) and prepares each gav / local file / remote file dependency.
- Downloads missing artifacts to a local Maven repository (default `~/.m2/repository`),
  verifying `.sha1` and refetching corrupted files. Releases and SNAPSHOTs share one
  native-layout repo; each SNAPSHOT resolves its latest build from upstream (micdn `latest`
  header, then `maven-metadata.xml`), falling back to the local copy when offline.
- Remotes: releases default to Aliyun -> Huawei -> Maven Central (`--remote` overrides);
  SNAPSHOTs use `--snapshot-remote` (optional, no fallback to `--remote`). `--offline`
  never touches the network.
- Per-component runtime directory `<base root>/<component key>`, root default
  `/var/tmp/jstart` (`--base`, spec `[app] base` / `[app] instance`). jstart never tracks or
  stops instances: after `exec` the process *is* the app, so pid and lifecycle belong to the
  caller. Run several replicas by giving each its own base.
- `run` execs `java` directly (no parent/child), forwarding `--port=8080` style args to the
  app and `-D`/`-X` args to the JVM. The main class is chosen by `--main=` > spec
  `[app] main` > the jar's `Main-Class`.
- War targets start via a declared engine `init` command (`[engine] init = <path|command>`);
  the engine and container jars are listed line by line under `[engine]`. Multiple wars go
  in `[subapp <id>]` sections, each with its own classloader and context.
- Native `tar.gz` targets (`g:a:tar.gz:<classifier>:v`, local file, or url) are fetched,
  extracted to `<base>/app`, and their executable is exec'd with the remaining args appended.
  `fetch` reuses the same logic, downloading only a bsdiff patch when a local baseline
  exists.
- All downloads go through the host `curl` command; dependencies are fetched in parallel
  (`--jobs=10`), with ranged parallel downloads for large files that support it.
- Output levels: by default warnings/errors, command results, and one
  `<label> Downloaded <url> (...)` line per download on **stderr**; `--verbose` adds progress
  detail, `--quiet` silences everything but command results.

> **Design constraint**: no transitive dependency resolution. The manifest is the single
> source of dependencies and must be written in full by the build-time beangle maven/sbt
> plugins; anything missing makes `resolve`/`run` fail.

## Quick start

```bash
dub build -b release --compiler=ldc2        # produces target/jstart

# Prepare dependencies and launch (the process becomes java; args pass through)
./target/jstart run /path/to/app.jar --port=8080 --path=/base

# Prepare only, printing the app's absolute path
app=$(./target/jstart --quiet resolve /path/to/app.jar)

# Declarative launch via a launch spec (.jstart, local path or http(s) url)
cat > app.jstart <<'JSTART_SPEC_EOF'
[app]
entry = /path/to/app.war

[engine]
init = /opt/engine/bin/tomcat-init
org.beangle.bas:beangle-bas-engine:0.13.17
org.apache.tomcat.embed:tomcat-embed-core:11.0.24

[args]
--port=8080
JSTART_SPEC_EOF
./target/jstart run app.jstart
./target/jstart run https://repo.example.com/app.jstart

# Print Main-Class@classpath for launch.sh-style scripts
meta=$(./target/jstart --quiet classpath "$app")

# Structured info (app/main/dependency paths and sizes) for audits and CI
./target/jstart --quiet info "$app"

# Offline consolidation: copy dependencies from --source into --local
./target/jstart repo "$app" --local=/opt/offline-repo

# Fetch a distribution, downloading only the incremental patch when available
./target/jstart fetch org.beangle.ems:beangle-ems-portal:tar.gz:linux-amd64:4.20.14-SNAPSHOT --from=4.20.13
./target/jstart fetch https://host/path/app-1.0-linux-amd64.tar.gz

# Native (tar.gz): fetch -> extract -> run
boot=$(./target/jstart --quiet resolve org.beangle.ems:beangle-ems-portal:tar.gz:linux-amd64:4.20.14-SNAPSHOT)
"$boot" --port=8080
```

## Build and test

Needs a D toolchain (`dub` + `ldc2`/`dmd`). The host needs `curl`, plus `java` (via
`JAVA_HOME` or `PATH`) to run jars.

```bash
dub test --compiler=ldc2    # unit tests
bash test/smoke.sh          # end-to-end smoke tests (needs a release build first)
```

Deb/RPM packaging scripts live in `scripts/` (`build_rpm.sh`, `build_deb.sh`) and install
only `/usr/bin/jstart`.

## Docs

Command details, dependency file format, offline deployment, design notes, and build and
release instructions are in `docs/` (start at [docs/README.md](docs/README.md)).

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
