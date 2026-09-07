/**
 * jstart - a lightweight jar/war booter written in D.
 *
 * It resolves a jar/war application, prepares the dependency environment by
 * downloading missing artifacts into the local maven repository, then
 * launches the application. Arguments such as --port=8080 are passed to the
 * application untouched.
 */
module app;

import std.array : join;
import std.stdio : stderr, writeln;
import std.string : startsWith, strip;

import jstart.launcher : runJarApp;
import jstart.repo : LocalRepo, RemoteRepo, buildRemotes;
import jstart.resolver : Resolver;

/// Version of the jstart binary.
enum jstartVersion = "0.0.1";

/// Parsed command line.
struct BootArgs {
  /// resolve | classpath | run
  string command = "run";
  string target;
  /// Everything not consumed by jstart itself.
  string[] rest;
  string local;
  string remote;
  /// --source: 源仓库目录（repo 命令从该仓库复制依赖）
  string source;
  bool preferWar;
  bool quiet;
  bool help;
  bool showVersion;
}

/// Parse jstart options; unrecognized arguments end up in rest.
BootArgs parseArgs(string[] args) {
  BootArgs r;
  foreach (a; args) {
    if (a == "-h" || a == "--help") {
      r.help = true;
    } else if (a == "-V" || a == "--version") {
      r.showVersion = true;
    } else if (a == "--quiet" || a == "-q") {
      r.quiet = true;
    } else if (a == "--preferwar") {
      r.preferWar = true;
    } else if (a.startsWith("--local=")) {
      r.local = a["--local=".length .. $];
    } else if (a.startsWith("--remote=")) {
      r.remote = a["--remote=".length .. $];
    } else if (a.startsWith("--source=")) {
      r.source = a["--source=".length .. $];
    } else if (r.target.length == 0 && (a == "resolve" || a == "classpath" || a == "run"
        || a == "repo")) {
      r.command = a;
    } else if (r.target.length == 0 && !a.startsWith("-")) {
      r.target = a;
    } else {
      r.rest ~= a;
    }
  }
  return r;
}

/// Print usage to stdout or stderr.
void usage() {
  writeln("jstart " ~ jstartVersion ~ " - a lightweight booter for jar/war applications");
  writeln("");
  writeln("Usage:");
  writeln("  jstart [options] run <target> [args...]");
  writeln("      Prepare dependencies then exec java: the process becomes");
  writeln("      java itself. Unrecognized args (like --port=8080) are passed");
  writeln("      to the application; -D/-X* args go to the JVM.");
  writeln("  jstart [options] resolve <target>");
  writeln("      Prepare dependencies and print the resolved app path.");
  writeln("  jstart [options] classpath <target>");
  writeln("      Print Main-Class@classpath after dependencies are ready.");
  writeln("  jstart [options] repo <target> [--source=<dir>]");
  writeln("      Offline consolidation: copy dependencies missing in the");
  writeln("      --local repo from the --source repo, then print the local");
  writeln("      repo base. <target> must be a local jar/war/dir/deps file.");
  writeln("");
  writeln("target:");
  writeln("  /path/to/app.jar | app.war | exploded-war-dir | plain deps file");
  writeln("  group:artifact:version | gav://group:artifact:version");
  writeln("  http(s)://host/path/to/app.jar");
  writeln("");
  writeln("options:");
  writeln("  --local=<dir>    local repository (default ~/.m2/repository)");
  writeln("  --source=<dir>   source repository for the repo command");
  writeln("                   (default ~/.m2/repository, must differ from --local)");
  writeln("  --remote=<urls>  comma separated remote repositories");
  writeln("  --preferwar      for gav targets, prefer the war packaging");
  writeln("  --quiet          suppress info output");
  writeln("  -h, --help       show this help");
  writeln("  -V, --version    print the version");
}

int main(string[] args) {
  auto opts = parseArgs(args[1 .. $]);
  if (opts.help) {
    usage();
    return 0;
  }
  if (opts.showVersion) {
    writeln("jstart " ~ jstartVersion);
    return 0;
  }
  if (opts.target.length == 0) {
    usage();
    return 2;
  }

  if (opts.command == "repo") {
    return runRepo(opts);
  }

  auto localRepo = new LocalRepo(opts.local);
  auto remotes = buildRemotes(opts.remote);
  auto resolver = new Resolver(localRepo, remotes, !opts.quiet, opts.preferWar);

  auto appPath = resolver.fetchTarget(opts.target);
  if (appPath.length == 0) {
    return 1;
  }
  auto deps = resolver.resolveDependencies(appPath);
  auto missing = resolver.ensureDependencies(deps);

  if (opts.command == "resolve") {
    writeln(appPath);
    return missing.length ? 1 : 0;
  }

  if (missing.length > 0) {
    stderr.writeln("Missing: " ~ missing.join(","));
    return 1;
  }

  auto mainClass = resolver.mainClassOf(appPath);
  auto classpath = resolver.buildClasspath(appPath, deps);

  if (opts.command == "classpath") {
    auto main = mainClass.length ? mainClass : "none";
    writeln(main ~ "@" ~ classpath);
    return 0;
  }

  // command == "run"
  if (mainClass.length == 0) {
    stderr.writeln("Cannot find Main-Class in MANIFEST.MF of " ~ appPath);
    stderr.writeln(
        "War or non-executable targets need an embedded engine, which is a future feature.");
    return 1;
  }

  // Split rest into jvm options (-D/-X*) and application args.
  // Everything else, e.g. --port=8080, goes to the application.
  string[] jvmOptions;
  string[] appArgs;
  foreach (a; opts.rest) {
    if (a.startsWith("-D") || a.startsWith("-X")) {
      jvmOptions ~= a;
    } else {
      appArgs ~= a;
    }
  }
  return runJarApp(classpath, mainClass, jvmOptions, appArgs, !opts.quiet);
}

/** Canonical directory path, resolving symlinks when possible. */
private string canonicalDir(string path) {
  import std.path : absolutePath;
  import std.string : toStringz;

  version (Posix) {
    import core.sys.posix.stdlib : realpath;
    import core.stdc.string : strlen;

    char[8192] buf;
    auto rp = realpath(path.toStringz, buf.ptr);
    if (rp !is null) {
      return rp[0 .. strlen(rp)].idup;
    }
  }
  return absolutePath(path);
}

/**
 * repo 子命令：仿照 org.beangle.boot.launcher.Repo，做离线仓库整合。
 * 解析 target 的依赖描述，把 --local 仓库缺失的构件从 --source 仓库复制过来，
 * 成功时输出 local 仓库基目录。
 */
private int runRepo(BootArgs opts) {
  import std.file : exists, isDir, isFile;

  import jstart.archive : expandLocalPath;
  import jstart.consolidate : consolidateArtifacts;
  import jstart.repo : LocalRepo;
  import jstart.resolver : Resolver;

  auto target = expandLocalPath(opts.target);
  if (!exists(target) || (!isFile(target) && !isDir(target))) {
    if (!opts.quiet) {
      stderr.writeln("Cannot find " ~ opts.target);
    }
    return 1;
  }
  auto localRepo = new LocalRepo(opts.local);
  auto sourceRepo = new LocalRepo(opts.source);
  if (canonicalDir(localRepo.base) == canonicalDir(sourceRepo.base)) {
    if (!opts.quiet) {
      stderr.writeln("Source and local repo cannot be the same: " ~ localRepo.base);
    }
    return 1;
  }
  auto resolver = new Resolver(localRepo, [], !opts.quiet);
  auto deps = resolver.resolveDependencies(target);
  auto missing = consolidateArtifacts(deps, sourceRepo, localRepo);
  if (missing.length > 0) {
    if (!opts.quiet) {
      stderr.writeln("Missing: " ~ missing.join(","));
    }
    return 1;
  }
  writeln(localRepo.base);
  return 0;
}
