/**
 * jstart - a lightweight launcher for jar/war and native (tar.gz) artifacts
 * written in D.
 *
 * It resolves a jar/war application or a GraalVM native distribution (tar.gz),
 * prepares the dependency environment by downloading missing artifacts into
 * the local maven repository, then launches the application. Arguments such as
 * --port=8080 are passed to the application untouched.
 */
module app;

import std.algorithm : endsWith;
import std.array : join;
import std.conv : to;
import std.file : exists, isDir, isFile, readText, remove, write;
import std.path : buildPath;
import std.stdio : stderr, writeln;
import std.string : startsWith, strip;

import jstart.archive : Archive, expandLocalPath, parseGav;
import jstart.base : PidInfo, currentPid, nativeDirName, pidFilePath, processAlive,
  processStartTime, readPidFile, removePidFile, resolveBase, stopApplication, stopNotRunning,
  writePidFile;
import jstart.distrepo : fetchDist;
import jstart.engine : EngineSel, appendEngineDeps, defaultDistEngineDeps, defaultEngineDeps,
  distTomcatEntryMain, entryArgvFile, entryClasspathFile, expandEngineDeps, parseEngineSel,
  parseEntryArgv, webappsPlanFile;
import jstart.http : runProcessCapture;
import jstart.launcher : execCommand, javaFor, printCommand, printJavaCommand, runJarApp,
  runNativeApp;
import jstart.mainclass : MainClass, MainSource, isPlausibleMainClass, pickMainClass,
  sourceName;
import jstart.native : extractTarGz, findExecutable, isNativeTarget, targetGav;
import jstart.repo : LocalRepo, RemoteRepo, buildRemotes, buildSnapshotRemotes;
import jstart.resolver : Resolver;
import jstart.spec : LaunchSpec, isSpecFile, parseLaunchSpec, validateLaunchSpec;

/// Version of the jstart binary.
enum jstartVersion = "0.0.1";

/// Parsed command line.
struct BootArgs {
  /// resolve | classpath | info | run | repo
  string command = "run";
  string target;
  /// Everything not consumed by jstart itself.
  string[] rest;
  string local;
  string remote;
  /// --snapshot-remote: SNAPSHOT 专用上游（不兜到 --remote）
  string snapshotRemote;
  /// --from: fetch 的增量补丁基线版本
  string from;
  /// --base: base 根目录（默认 /var/tmp/jstart；组件目录为 <base>/<组件键>）
  string base;
  /// --instance: 命名组件目录（<根>/<name>-<组件指纹>），同一组件跑多副本时用
  string instance;
  /// --main: 覆盖 java 主类（优先于 [app] main 与 MANIFEST.MF 的 Main-Class）
  string mainClass;
  /// --main 是否出现过（空值要报错，不能当成"没给"）
  bool hasMain;
  /// --timeout: stop 等待进程退出的秒数（默认 15）
  int stopTimeout = 15;
  /// --force: run 时忽略已在运行的实例；stop 时超时后用 SIGKILL
  bool force;
  /// --source: 源仓库目录（repo 命令从该仓库复制依赖）
  string source;
  /// --print: 只打印将要执行的命令，不 exec。
  bool print;
  /// 并行下载并发数（--jobs），1 = 串行。
  int jobs = 10;
  /// --verbose: 输出解析/下载/写 pid/启动命令等过程细节。
  bool verbose;
  /// --quiet: 连告警也静默（比默认更安静）。
  bool quiet;
  /// --offline: 只用本地仓库，不做任何远程探测与下载。
  bool offline;
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
    } else if (a == "--verbose" || a == "-v") {
      r.verbose = true;
    } else if (a == "--print") {
      r.print = true;
    } else if (a.startsWith("--jobs=")) {
      auto n = 0;
      try {
        import std.conv : to;

        n = to!int(a["--jobs=".length .. $].strip);
      } catch (Exception e) {
        n = 0;
      }
      r.jobs = n < 1 ? 1 : n;
    } else if (a.startsWith("--local=")) {
      r.local = a["--local=".length .. $];
    } else if (a.startsWith("--remote=")) {
      r.remote = a["--remote=".length .. $];
    } else if (a.startsWith("--snapshot-remote=")) {
      r.snapshotRemote = a["--snapshot-remote=".length .. $];
    } else if (a.startsWith("--source=")) {
      r.source = a["--source=".length .. $];
    } else if (a.startsWith("--from=")) {
      r.from = a["--from=".length .. $];
    } else if (a.startsWith("--base=")) {
      r.base = a["--base=".length .. $];
    } else if (a.startsWith("--instance=")) {
      r.instance = a["--instance=".length .. $];
    } else if (a.startsWith("--main=")) {
      r.mainClass = a["--main=".length .. $].strip;
      r.hasMain = true;
    } else if (a.startsWith("--timeout=")) {
      auto n = 0;
      try {
        import std.conv : to;

        n = to!int(a["--timeout=".length .. $].strip);
      } catch (Exception e) {
        n = 0;
      }
      r.stopTimeout = n < 1 ? 1 : n;
    } else if (a == "--force") {
      r.force = true;
    } else if (a == "--offline") {
      r.offline = true;
    } else if (r.target.length == 0 && (a == "resolve" || a == "classpath" || a == "info"
        || a == "run" || a == "repo" || a == "fetch" || a == "stop")) {
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
  writeln("jstart " ~ jstartVersion
      ~ " - a lightweight launcher for jar/war and native (tar.gz) artifacts");
  writeln("");
  writeln("Usage:");
  writeln("  jstart [options] run <target> [args...]");
  writeln("      Prepare dependencies then exec the runtime: the process");
  writeln("      becomes the runtime itself (java for jar targets; a war target");
  writeln("      must be declared by a launch spec's [app] entry and runs the");
  writeln("      built-in engine, see docs/war-engine.md; tar.gz targets are");
  writeln("      extracted and their executable is run).");
  writeln("      Unrecognized args (like --port=8080) are passed to the");
  writeln("      application; -D/-X* args go to the runtime. <target> may");
  writeln("      also be a launch spec (.jstart) declaring main/entry/runtime/args");
  writeln("  jstart [options] resolve <target>");
  writeln("      Prepare dependencies and print the resolved app path.");
  writeln("  jstart [options] classpath <target>");
  writeln("      Print Main-Class@classpath after dependencies are ready.");
  writeln("  jstart [options] info <target>");
  writeln("      Print structured info (app/main/deps/local paths and sizes) after");
  writeln("      dependencies are ready; useful for auditing and CI integration.");
  writeln("  jstart [options] repo <target> [--source=<dir>]");
  writeln("      Offline consolidation: copy dependencies missing in the");
  writeln("      --local repo from the --source repo, then print the local");
  writeln("      repo base. <target> must be a local jar/war/exploded dir/launch spec.");
  writeln("  jstart [options] fetch <target> [--from=<version>] [--remote=<base>]");
  writeln("      Download a target and print its local path. <target> may be a");
  writeln("      gav (dist artifact: native-image tar.gz / jar / war, preferring");
  writeln("      a bsdiff delta from --from over the whole artifact), a local");
  writeln("      file (printed as is) or an http(s) url (cached in the local repo).");
  writeln("      tar.gz and plain jar/war share the same delta logic; only how");
  writeln("      the patch is applied differs (tar.gz: gunzip -> bspatch -> gzip).");
  writeln("      <gav> accepts a classifier, e.g.");
  writeln("      org.beangle:beangle-ems-portal:tar.gz:linux-amd64:4.20.14-SNAPSHOT");
  writeln("  jstart [options] stop <target> [--base=<dir>] [--timeout=<sec>] [--force]");
  writeln("      Stop the application started by `run <target>`: read the pid");
  writeln("      file in the component base, send SIGTERM and wait for it to");
  writeln("      exit (--force sends SIGKILL after the timeout). No application");
  writeln("      arguments are needed: an instance is identified by component +");
  writeln("      base. Exits 0 when stopped, 3 when nothing was running");
  writeln("      (missing/stale pid file).");
  writeln("");
  writeln("target:");
  writeln("  /path/to/app.jar | app.war | exploded-war-dir");
  writeln("  /path/to/app.jstart                launch spec declaring main/entry/runtime/args");
  writeln("  /path/to/app.tar.gz                native-image distribution (extracted and run)");
  writeln("  group:artifact:version | gav://group:artifact:version");
  writeln("  group:artifact:tar.gz:<classifier>:version   native distribution (see fetch)");
  writeln("  http(s)://host/path/to/app.jar");
  writeln("  http(s)://host/path/to/app.jstart  remote launch spec (downloaded and parsed)");
  writeln("");
  writeln("  run 需要可启动的应用本体：jar/gav/url/解压目录，或写成 launch spec");
  writeln("  （.jstart，支持本地或 http(s)，见 docs/launch-spec.md）。本地文件 target 只接受");
  writeln("  jar/war/解压目录；纯文本依赖清单已不支持。");
  writeln("  war 例外：run 不能直接吃 war（本地/url/gav 皆然），必须写 launch spec 并用");
  writeln("  [app] entry 声明；resolve/fetch/repo 仍可直接接受 war。");
  writeln("  java 目标的主类按 --main > launch spec [app] main > jar 内 MANIFEST.MF");
  writeln("  Main-Class 的顺序确定（解压目录没有 manifest，只能靠前两者）。");
  writeln("  tar.gz（native）目标：取发行包（同 fetch，gav 时含增量补丁）后解压到");
  writeln("  <base>/app（base = <base 根>/<组件键>，根默认 /var/tmp/jstart），");
  writeln("  exec 解压出的可执行文件，[args]/命令行参数按序附加在其后；resolve 输出该");
  writeln("  可执行文件路径，可执行文件位置用 launch spec [app] exec= 指定。");
  writeln("  base：组件的运行基目录（pid 文件、native 解压、引擎 docBase 与 argv 都在其中）。一个组件");
  writeln("  的一个 base 只能跑一个实例——跑多个副本请给每个副本不同的 --base/--instance；");
  writeln("  参数不参与实例身份，因此 run/stop 不需要给同样的参数。");
  writeln("");
  writeln("options:");
  writeln("  --local=<dir>    local repository (default ~/.m2/repository)");
  writeln("  --source=<dir>   source repository for the repo command");
  writeln("                   (default ~/.m2/repository, must differ from --local)");
  writeln("  --remote=<urls>  comma separated remote repositories");
  writeln("                   (release artifacts; Central is appended, and the");
  writeln("                   built-in mirrors are used when the option is absent)");
  writeln("  --snapshot-remote=<urls>  optional comma separated SNAPSHOT upstreams;");
  writeln("                   used for SNAPSHOT only, never falling back to --remote");
  writeln("                   (no default mirrors, no Central fallback); without it a");
  writeln("                   SNAPSHOT already in the local snapshot library is used");
  writeln("                   as-is, and only a missing one is an error");
  writeln("  --offline        use the local repositories only: no remote probing");
  writeln("                   and no downloads (missing artifacts fail instead)");
  writeln("  --from=<version> fetch/native gav: delta baseline version (default: the");
  writeln("                   newest local version lower than the requested one)");
  writeln("  --base=<dir>     run/stop: the base root, replacing the default");
  writeln("                   /var/tmp/jstart. A component's state lives in");
  writeln("                   <base>/<组件键>/: app.pid, app/ (native");
  writeln("                   extraction) and webapps/ (war explosion). One");
  writeln("                   component + base runs one instance; copies");
  writeln("                   need their own base");
  writeln("  --instance=<name>  run/stop: name the component directory");
  writeln("                   (<根>/<name>-<组件指纹>) instead of using the");
  writeln("                   target's file name; needs no --base=<dir>");
  writeln("  --main=<class>   run/classpath/info: java main class, overriding");
  writeln("                   [app] main and the jar's Main-Class manifest");
  writeln("                   entry; only for jar/dir targets, ignored for");
  writeln("                   war/native");
  writeln("  --timeout=<sec>  stop: seconds to wait after SIGTERM (default 15)");
  writeln("  --force          run: start even if the pid file says it is running;");
  writeln("                   stop: SIGKILL after the timeout");
  writeln("  --print          run only: print the command to execute (no exec)");
  writeln("  --jobs=N         parallel dependency downloads (default 10, 1 = serial)");
  writeln("  --verbose, -v    show progress details (resolve/download/explode/exec)");
  writeln("  --quiet          suppress warnings and progress (exit code still tells)");
  writeln("  -h, --help       show this help");
  writeln("  -V, --version    print the version");
}

/**
 * 过程细节（resolving/downloading/exploding/running 等）是否输出：只有
 * --verbose 打开且未给 --quiet 时才输出；默认只保留告警与命令结果。
 */
private bool showProgress(BootArgs opts) {
  return opts.verbose && !opts.quiet;
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

  // --main 是 jstart 选项（只在本地消费、不转发给应用）：空值或明显不是类名
  // （路径/url/带空格）时立刻报错，避免留到 JVM 报一句难懂的错误。
  if (opts.hasMain && !isPlausibleMainClass(opts.mainClass)) {
    stderr.writeln("Invalid --main value"
        ~ (opts.mainClass.length ? " `" ~ opts.mainClass ~ "`" : "")
        ~ ": expected a java class name, e.g. --main=com.example.Main.");
    return 2;
  }

  // --print 只对 run 有意义：打印将要执行的命令行（当前即 java）。
  if (opts.print && opts.command != "run") {
    stderr.writeln("--print is only supported by the run command");
    return 2;
  }

  if (opts.command == "repo") {
    return runRepo(opts);
  }
  if (opts.command == "fetch") {
    return runFetch(opts);
  }

  auto localRepo = new LocalRepo(opts.local);
  auto resolver = new Resolver(localRepo, remotesOf(opts), showProgress(opts),
      opts.quiet, opts.offline, snapshotRemotesOf(opts));

  // launch spec：target 必须以 .jstart 结尾（本地路径或 http(s) url）。
  // http(s) spec 先下载并缓存到本地仓库，再按本地文件解析。
  auto specLocal = opts.target;
  if (isSpecFile(opts.target)
      && (opts.target.startsWith("http://") || opts.target.startsWith("https://"))) {
    specLocal = resolver.fetchTarget(opts.target);
    if (specLocal.length == 0) {
      return 1;
    }
  }
  LaunchSpec spec;
  auto specMode = tryLoadSpec(opts, specLocal, spec);
  if (specMode) {
    auto invalid = validateLaunchSpec(spec);
    if (invalid.length > 0) {
      stderr.writeln(invalid);
      return 1;
    }
  }
  if (specMode && spec.subapps.length == 0 && spec.entry.length == 0) {
    stderr.writeln("Missing entry in launch spec: " ~ opts.target);
    return 1;
  }
  if (!specMode && opts.command != "stop") {
    auto reject = plainTargetReject(opts);
    if (reject.length > 0) {
      stderr.writeln(reject);
      return 1;
    }
  }

  // stop：只按 base 里的 pid 文件停应用——不取包、不准备依赖、也不需要应用参数
  // （实例身份 = 组件 + base），因此包被清理或网络不可用时照样能停。
  if (opts.command == "stop") {
    auto base = resolveBase(opts.target, baseOption(opts, specMode ? spec : LaunchSpec.init),
        opts.instance);
    if (base.length == 0) {
      stderr.writeln("Cannot prepare the component base for " ~ opts.target
          ~ "; pass a writable --base=<dir>.");
      return 1;
    }
    auto pidPath = pidFilePath(base);
    auto existed = exists(pidPath);
    auto code = stopApplication(pidPath, opts.stopTimeout, opts.force, !opts.quiet);
    if (code == stopNotRunning && !existed && !opts.quiet) {
      stderr.writeln("Hint: an instance is identified by component + base; if it was "
          ~ "started with --base=<dir> or --instance=<name>, pass the same one here.");
    }
    if (opts.rest.length && !opts.quiet) {
      stderr.writeln("Note: application arguments are ignored by stop "
          ~ "(identity = component + base).");
    }
    return code;
  }

  // 多应用 spec（[subapp <id>]）：一个 dist 引擎在同一 JVM 里跑多个 webapp，各占一个
  // context path。stop 已按 base 处理，这里处理 run/resolve/info/classpath。
  if (specMode && spec.subapps.length > 0) {
    return runMultiWebapp(opts, resolver, spec);
  }

  // native（GraalVM tar.gz）目标：取包 -> 解压 -> 定位可执行文件，后面直接
  // exec 它（没有 JVM，也没有单独的运行时）。
  auto target = specMode ? spec.entry : opts.target;
  auto nativeMode = isNativeTarget(target);
  string nativeArchive;
  string nativeRoot;
  string appPath;
  // base：组件的运行基目录（pid 文件、native 解压、引擎 docBase 与 argv 都在其中）。run 需要，
  // native 的 resolve/info 因为要解压也需要。
  string base;
  if (opts.command == "run" || nativeMode) {
    base = resolveBase(opts.target, baseOption(opts, specMode ? spec : LaunchSpec.init),
        opts.instance);
    if (base.length == 0) {
      stderr.writeln("Cannot prepare the component base for " ~ opts.target
          ~ "; pass a writable --base=<dir>.");
      return 1;
    }
  }
  // pid 文件：run 在 exec 前写入（exec 后本进程就是应用，pid 即应用 pid）。
  string pidPath;
  if (opts.command == "run" && !opts.print) {
    bool fatal;
    pidPath = preparePidFile(opts, base, target, fatal);
    if (fatal) {
      return 1;
    }
  }
  // 启动失败（没能 exec 成应用）时清掉刚写的 pid 文件；exec 成功后本进程
  // 就是应用，这段代码不会再执行，pid 文件留给 stop 使用。
  scope (exit) removePidOnExit(pidPath);
  if (nativeMode) {
    nativeArchive = fetchArtifact(opts, resolver, target);
    if (nativeArchive.length == 0) {
      return 1;
    }
    auto execHint = specMode ? spec.exec : "";
    auto artifactId = nativeArtifactId(target);
    // 解压到 <base>/app：base 按组件（--base/--instance 可换），不用包旁目录兜底。
    auto extractDir = buildPath(base, nativeDirName);
    string[] candidates;
    auto extracted = extractTarGz(nativeArchive, showProgress(opts), false, extractDir);
    if (extracted.ok) {
      appPath = findExecutable(extracted.dir, execHint, artifactId, candidates);
    }
    if (appPath.length == 0 && extracted.ok && extracted.reused) {
      // 复用的解压目录不完整/被改动：强制重解一次
      extracted = extractTarGz(nativeArchive, showProgress(opts), true, extractDir);
      if (extracted.ok) {
        appPath = findExecutable(extracted.dir, execHint, artifactId, candidates);
      }
    }
    if (appPath.length == 0) {
      if (extracted.ok) {
        reportNativeExecMissing(nativeArchive, candidates, execHint);
      }
      return 1;
    }
    nativeRoot = extracted.dir;
  } else {
    appPath = resolver.fetchTarget(target);
    if (appPath.length == 0) {
      return 1;
    }
  }
  if (specMode && !nativeMode && !appPath.endsWith(".war") && !isDir(appPath)
      && (spec.engine.length > 0 || spec.hasEngineDeps) && !opts.quiet) {
    stderr.writeln("Warning: [app] engine / [engine] applies to war targets "
        ~ "(a war file or an exploded webapp directory), ignored.");
  }
  Archive[] deps;
  if (specMode && spec.hasDeps) {
    // 显式 [deps] 段是唯一来源，不再回退读取 entry 内置依赖清单。
    deps = resolver.parseDependencyText(spec.deps.join("\n"));
  } else if (!nativeMode) {
    deps = resolver.resolveDependencies(appPath);
  }
  auto missing = resolver.ensureDependencies(deps, opts.jobs);

  if (opts.command == "resolve") {
    writeln(appPath);
    return missing.length ? 1 : 0;
  }

  if (missing.length > 0) {
    stderr.writeln("Missing: " ~ missing.join(","));
    return 1;
  }

  if (nativeMode) {
    return runNative(opts, resolver, appPath, deps, specMode, spec, nativeArchive, nativeRoot);
  }

  auto manifestMain = resolver.mainClassOf(appPath);
  auto mainClass = pickMainClass(opts.mainClass, specMode ? spec.main : "", manifestMain);
  auto classpath = resolver.buildClasspath(appPath, deps);

  if (opts.command == "classpath") {
    auto main = mainClass.name.length ? mainClass.name : "none";
    writeln(main ~ "@" ~ classpath);
    return 0;
  }

  if (opts.command == "info") {
    return printInfo(opts, resolver, appPath, deps, mainClass, specMode, spec);
  }

  // command == "run"
  // 引擎目标：war 文件，或"目录 + 显式 [app] engine/[engine] 声明"的已解压 webapp。
  // 后者让 jstart 按 spec 启动一个解压好的 web 项目目录（引擎直接用它作 docBase）。
  auto engineDeclared = specMode && (spec.engine.length > 0 || spec.hasEngineDeps);
  if (appPath.endsWith(".war") || (engineDeclared && isDir(appPath))) {
    // war 只能通过 launch spec 运行：引擎 / 参数 / base 都需要显式声明
    // （见 docs/engine.md）。resolve/fetch/repo 对 war 的支持不受此限制。
    if (appPath.endsWith(".war") && !specMode) {
      stderr.writeln("war targets must run through a launch spec: write a .jstart file\n"
          ~ "  [app]\n  entry = " ~ opts.target ~ "\n  engine = tomcat\n"
          ~ "then run `jstart run app.jstart` (see docs/engine.md). "
          ~ "resolve/fetch still accept a war directly.");
      return 1;
    }
    if (!opts.quiet && (opts.hasMain || (specMode && spec.main.length > 0))) {
      warnIgnoredMain(opts, true, spec, "war");
      stderr.writeln("Note: a war runs an engine entry main; "
          ~ "pick it with [app] engine (see docs/engine.md).");
    }
    return runEngine(opts, resolver, appPath, deps, spec, base);
  }
  if (mainClass.empty) {
    stderr.writeln("Cannot find Main-Class in MANIFEST.MF of " ~ appPath);
    stderr.writeln("Pass --main=<class>, write a launch spec (.jstart) with [app] main, "
        ~ "or keep a Main-Class in the jar manifest.");
    return 1;
  }

  // 运行时参数与 app args：spec 在前，命令行追加在后（-D/-X* 归运行时，
  // java 即 JVM 参数；其余归应用）。
  string[] runtimeOptions = specMode ? spec.runtimeOptions.dup : null;
  string[] appArgs = specMode ? spec.args.dup : null;
  foreach (a; opts.rest) {
    if (a.startsWith("-D") || a.startsWith("-X")) {
      runtimeOptions ~= a; // -D/-X 是 java 运行时参数，仍归运行时
    } else {
      appArgs ~= a;
    }
  }

  if (!opts.print && specMode && spec.workingDir.length > 0) {
    auto dir = expandLocalPath(spec.workingDir);
    if (!changeDir(dir)) {
      stderr.writeln("Cannot chdir to " ~ dir);
      return 1;
    }
  }

  // spec [app] runtime：显式指定运行时/解释器可执行文件（chdir 前展开，与
  // entry/working_dir 一致的 ~ 与 ${VAR} 语义）；jar 缺省按 JAVA_HOME/PATH 取 java。
  auto runtimeCmd = specMode && spec.runtime.length > 0 ? expandLocalPath(spec.runtime) : "";

  if (opts.print) {
    return printJavaCommand(classpath, mainClass.name, runtimeOptions, appArgs, runtimeCmd);
  }
  return runJarApp(classpath, mainClass.name, runtimeOptions, appArgs, showProgress(opts),
      runtimeCmd);
}

/**
 * run 的引擎分支：先运行**引擎入口 main** 准备引擎环境（解压 war/发行包、写
 * 容器配置），再 exec 它写出的最终启动命令（进程仍变为 java，无父子等待）。
 *
 * 与旧实现（jstart 自行爆炸 war 后直接 exec Bootstrap）不同：docBase 布局与 war
 * 爆炸都收敛到引擎侧，jstart 不再镜像布局公式，也不再有"跨仓库契约"。协议见
 * docs/engine.md。
 *
 * - [app] engine：内置别名 tomcat|undertow（war 缺省 tomcat，可带 tomcat 版本
 *   后缀），或含 "." 的入口 main FQCN；
 * - [engine] 段：引擎 jar 清单（同 [deps] 语法，行内可用
 *   {tomcat.version}/{sas.version} 占位符）；段存在即为准。缺省用内置目录
 *   （tomcat 支持 engine = tomcat-<版本> 重钉两个 tomcat-embed jar）；FQCN 入口
 *   main 没有内置目录，必须显式声明 [engine]；
 * - 入口 main 以 `java -cp <引擎 jar> <entryMain> --base= --entry= --app-classpath-file=
 *   --entry-out= [--app-jvm-arg=...] <透传参数>` 运行，把最终 argv（NUL 分隔）
 *   写入 --entry-out 文件；非 0 退出即失败；
 * - base 就是组件的 base（--base/--instance/[app] base）；--path/--port 等参数
 *   一律原样交给入口 main 转发（jstart 不再读取 --path）；
 * - --print：照常准备（跑入口 main），但只打印最终命令不 exec。
 */
private int runEngine(BootArgs opts, Resolver resolver, string entry,
    Archive[] appDeps, LaunchSpec spec, string base) {
  EngineSel sel;
  try {
    sel = parseEngineSel(spec.engine.length > 0 ? spec.engine : "tomcat");
  } catch (Exception e) {
    stderr.writeln(e.msg);
    return 1;
  }

  // 引擎依赖：[engine] 段罗列为准（占位符先展开）；别名缺省用内置目录，
  // FQCN 入口 main 没有内置目录。
  Archive[] engineDeps;
  if (spec.hasEngineDeps) {
    auto lines = spec.engineDeps.dup;
    foreach (i, line; lines) {
      lines[i] = expandEngineDeps(line, sel.ver);
    }
    engineDeps = resolver.parseDependencyText(lines.join("\n"));
  } else if (sel.aliasName.length > 0) {
    try {
      engineDeps = defaultEngineDeps(sel.aliasName, sel.ver);
    } catch (Exception e) {
      stderr.writeln(e.msg);
      return 1;
    }
  } else if (sel.entryMain == distTomcatEntryMain) {
    // 全量 tomcat（ServerCreator）也有内置目录：beangle-sas-engine + tomcat 发行包 zip。
    engineDeps = defaultDistEngineDeps(sel.ver);
  } else {
    stderr.writeln("Engine entry main " ~ sel.entryMain
        ~ " has no built-in dependency catalog: declare its jars in the [engine] section.");
    return 1;
  }
  auto merged = appendEngineDeps(appDeps, engineDeps);
  auto missing = resolver.ensureDependencies(merged, opts.jobs);
  if (missing.length > 0) {
    stderr.writeln("Missing: " ~ missing.join(","));
    return 1;
  }

  // 运行时参数与透传参数拆分（与 jar 分支一致）：[runtime] 与 -D/-X 归 java（作为
  // --app-jvm-arg 交给入口 main 写进最终命令），其余（含 --path/--port）原样透传。
  string[] runtimeOptions = spec.runtimeOptions.dup;
  string[] passthrough = spec.args.dup;
  foreach (a; opts.rest) {
    if (a.startsWith("-D") || a.startsWith("-X")) {
      runtimeOptions ~= a;
    } else {
      passthrough ~= a;
    }
  }

  if (!opts.print && spec.workingDir.length > 0) {
    auto dir = expandLocalPath(spec.workingDir);
    if (!changeDir(dir)) {
      stderr.writeln("Cannot chdir to " ~ dir);
      return 1;
    }
  }

  auto java = javaFor(spec.runtime.length > 0 ? expandLocalPath(spec.runtime) : "");
  // 引擎 jar 与应用依赖分开：应用依赖写进 --app-classpath-file 交给入口 main，由它
  // 连同解压后的 docBase/WEB-INF 一起拼进最终 classpath（WEB-INF 的位置只有引擎知道）。
  auto engineCp = resolver.depsClasspath(engineDeps);
  auto appCp = resolver.buildClasspath("", appDeps);
  auto entryOut = buildPath(base, entryArgvFile);
  // 应用依赖 classpath 可能很长，写入文件由入口 main 读取，避免命令行超长
  auto appCpFile = buildPath(base, entryClasspathFile);
  write(appCpFile, appCp);

  auto engineCmd = [java, "-cp", engineCp, sel.entryMain,
      "--base=" ~ base, "--entry=" ~ entry, "--app-classpath-file=" ~ appCpFile,
      // 本地仓库地址透传给引擎入口 main（ServerCreator 转成 -Dsas.repo），
      // 使容器内的 DependencyClassLoader 也认 --local（快照与正式版同库）
      "--Dsas.repo=" ~ resolver.local.base,
      "--entry-out=" ~ entryOut];
  foreach (o; runtimeOptions) {
    engineCmd ~= "--app-jvm-arg=" ~ o;
  }
  engineCmd ~= passthrough;

  if (opts.print) {
    // 只打印：上次运行留下的 argv 文件存在时打印真实启动命令，否则打印引擎准备
    // 命令（准备过程可能有副作用，--print 不执行它）。
    if (exists(entryOut)) {
      auto saved = parseEntryArgv(readText(entryOut));
      if (saved.length > 0) {
        return printCommand(saved);
      }
    }
    return printCommand(engineCmd);
  }
  if (exists(entryOut)) {
    remove(entryOut); // 清掉上次残留，避免引擎准备失败时误读旧命令
  }

  auto pr = runProcessCapture(engineCmd, opts.verbose);
  if (pr.status != 0) {
    stderr.writeln("Engine entry main failed (exit " ~ pr.status.to!string ~ "): "
        ~ sel.entryMain);
    return pr.status;
  }
  if (opts.verbose && pr.stdoutText.strip.length > 0) {
    stderr.writeln(pr.stdoutText.strip);
  }
  if (!exists(entryOut)) {
    stderr.writeln("Engine entry main did not write " ~ entryOut);
    return 1;
  }
  auto argv = parseEntryArgv(readText(entryOut));
  if (argv.length == 0) {
    stderr.writeln("Engine entry main wrote an empty launch command to " ~ entryOut);
    return 1;
  }
  return execCommand(argv, showProgress(opts));
}

/**
 * 多应用 spec（`[subapp <id>]`）：一个 **dist 引擎**在同一 JVM 里跑多个 webapp，每个
 * 一个独立 context path。设计约定见 docs/engine.md：
 *
 *  - 多应用只走 Dist 模式，内嵌引擎（tomcat/undertow 别名、*EmbedCreator）只跑一个 webapp，
 *    在 spec 校验阶段即被拒绝；
 *  - jstart 逐个取回 webapp（war 文件或已解压目录）并**补齐各自依赖到本地仓库**——运行时
 *    由容器内每个 Context 自己的 DependencyClassLoader 按 war 清单解析（sas.repo 透传），
 *    jstart 不把多应用的依赖合并进同一个 JVM classpath（那样会串味）；
 *  - 每个 webapp 的入口与 context path 写进 `<base>/engine-webapps.tsv`（一行一个：
 *    `id \t entry \t path`），用 `--webapps-file=` 交给入口 main；单应用仍走
 *    `--entry=`/`--path=`/`--app-classpath-file=`；
 *  - 一个 base = 一个实例：一份 pid、一套 `webapps/`，多应用共享启停生命周期。
 */
private int runMultiWebapp(BootArgs opts, Resolver resolver, LaunchSpec spec) {
  import std.format : format;

  // base 与单应用一致（--base/--instance/[app] base）；多应用共享一个 base。
  auto base = resolveBase(opts.target, baseOption(opts, spec), opts.instance);
  if (base.length == 0) {
    stderr.writeln("Cannot prepare the component base for " ~ opts.target
        ~ "; pass a writable --base=<dir>.");
    return 1;
  }
  // 一个 base 一份 pid：多应用共享启停生命周期（stop 只需 base）。
  string pidPath;
  if (opts.command == "run" && !opts.print) {
    bool fatal;
    pidPath = preparePidFile(opts, base, opts.target, fatal);
    if (fatal) {
      return 1;
    }
  }
  scope (exit) removePidOnExit(pidPath);

  // 逐个取回 webapp 并补齐依赖：容器内 DependencyClassLoader 按 sas.repo 从本地仓库解析
  // 每个 war 的清单，因此这里必须确保构件已就位（与单应用同为 jstart 的解析结果）。
  string[] entries;
  bool missingAny;
  foreach (w; spec.subapps) {
    auto entry = resolver.fetchTarget(w.entry);
    if (entry.length == 0) {
      return 1;
    }
    entries ~= entry;
    auto deps = resolver.resolveDependencies(entry);
    auto missing = resolver.ensureDependencies(deps, opts.jobs);
    if (missing.length > 0) {
      stderr.writeln(format("[subapp %s] missing: %s", w.id, missing.join(",")));
      missingAny = true;
    }
  }

  if (opts.command == "resolve") {
    foreach (entry; entries) {
      writeln(entry);
    }
    return missingAny ? 1 : 0;
  }
  if (opts.command == "info") {
    if (missingAny) {
      return 1;
    }
    return printMultiWebappInfo(opts, resolver, spec, entries);
  }
  if (opts.command == "classpath") {
    stderr.writeln("classpath is not supported for multi-webapp specs: each webapp has "
        ~ "its own classpath (use `info`).");
    return 2;
  }
  // command == "run"
  if (missingAny) {
    return 1;
  }
  if (opts.hasMain || spec.main.length > 0) {
    warnIgnoredMain(opts, true, spec, "multi-webapp");
  }

  // 引擎：多应用只走 Dist。缺省 ServerCreator；给 FQCN 时按 FQCN，引擎依赖 [engine] 段为准，
  // 否则用 ServerCreator 的内置目录（beangle-sas-engine + tomcat 发行包 zip）。
  EngineSel sel;
  try {
    sel = parseEngineSel(spec.engine.length > 0 ? spec.engine : distTomcatEntryMain);
  } catch (Exception e) {
    stderr.writeln(e.msg);
    return 1;
  }
  Archive[] engineDeps;
  if (spec.hasEngineDeps) {
    auto lines = spec.engineDeps.dup;
    foreach (i, line; lines) {
      lines[i] = expandEngineDeps(line, sel.ver);
    }
    engineDeps = resolver.parseDependencyText(lines.join("\n"));
  } else if (sel.entryMain == distTomcatEntryMain) {
    engineDeps = defaultDistEngineDeps(sel.ver);
  } else {
    stderr.writeln("Engine entry main " ~ sel.entryMain
        ~ " has no built-in dependency catalog: declare its jars in the [engine] section.");
    return 1;
  }
  auto missingEngine = resolver.ensureDependencies(engineDeps, opts.jobs);
  if (missingEngine.length > 0) {
    stderr.writeln("Missing: " ~ missingEngine.join(","));
    return 1;
  }

  // 运行参数与应用参数拆分（与单应用 war 分支一致）：[runtime] 与 -D/-X 归 java，其余透传。
  string[] runtimeOptions = spec.runtimeOptions.dup;
  string[] passthrough = spec.args.dup;
  foreach (a; opts.rest) {
    if (a.startsWith("-D") || a.startsWith("-X")) {
      runtimeOptions ~= a;
    } else {
      passthrough ~= a;
    }
  }

  if (!opts.print && spec.workingDir.length > 0) {
    auto dir = expandLocalPath(spec.workingDir);
    if (!changeDir(dir)) {
      stderr.writeln("Cannot chdir to " ~ dir);
      return 1;
    }
  }

  // webapps 计划文件：每行 id \t entry \t path，交给入口 main（ServerCreator）逐个建 Context。
  auto planPath = buildPath(base, webappsPlanFile);
  string plan;
  foreach (i, w; spec.subapps) {
    plan ~= w.id ~ "\t" ~ entries[i] ~ "\t" ~ w.path ~ "\n";
  }
  write(planPath, plan);

  auto java = javaFor(spec.runtime.length > 0 ? expandLocalPath(spec.runtime) : "");
  auto engineCp = resolver.depsClasspath(engineDeps);
  auto entryOut = buildPath(base, entryArgvFile);
  auto engineCmd = [java, "-cp", engineCp, sel.entryMain,
      "--base=" ~ base, "--webapps-file=" ~ planPath,
      // 本地仓库地址透传（ServerCreator 转成 -Dsas.repo），容器内每个 Context 的
      // DependencyClassLoader 都从同一个仓库解析各自 war 的依赖清单。
      "--Dsas.repo=" ~ resolver.local.base,
      "--entry-out=" ~ entryOut];
  foreach (o; runtimeOptions) {
    engineCmd ~= "--app-jvm-arg=" ~ o;
  }
  engineCmd ~= passthrough;

  if (opts.print) {
    if (exists(entryOut)) {
      auto saved = parseEntryArgv(readText(entryOut));
      if (saved.length > 0) {
        return printCommand(saved);
      }
    }
    return printCommand(engineCmd);
  }
  if (exists(entryOut)) {
    remove(entryOut);
  }

  auto pr = runProcessCapture(engineCmd, opts.verbose);
  if (pr.status != 0) {
    stderr.writeln("Engine entry main failed (exit " ~ pr.status.to!string ~ "): "
        ~ sel.entryMain);
    return pr.status;
  }
  if (opts.verbose && pr.stdoutText.strip.length > 0) {
    stderr.writeln(pr.stdoutText.strip);
  }
  if (!exists(entryOut)) {
    stderr.writeln("Engine entry main did not write " ~ entryOut);
    return 1;
  }
  auto argv = parseEntryArgv(readText(entryOut));
  if (argv.length == 0) {
    stderr.writeln("Engine entry main wrote an empty launch command to " ~ entryOut);
    return 1;
  }
  return execCommand(argv, showProgress(opts));
}

/// 多应用 info：先给仓库/上游信息，再按 webapp 列出落盘路径、context path 与依赖。
private int printMultiWebappInfo(BootArgs opts, Resolver resolver, LaunchSpec spec,
    string[] entries) {
  import std.format : format;

  import jstart.archive : Artifact, LocalFile, RemoteFile;

  writeln("target: " ~ opts.target);
  writeln("type: multi-webapp");
  writeln("webapps: " ~ spec.subapps.length.to!string);
  writeln("local: " ~ resolver.local.base);
  writeln("snapshots: " ~ resolver.local.snapshotBase);
  string[] remotes;
  foreach (r; resolver.remotes) {
    remotes ~= r.base;
  }
  writeln("remotes: " ~ remotes.join(","));
  string[] snapshotRemotes;
  foreach (r; resolver.snapshotRemotes) {
    snapshotRemotes ~= r.base;
  }
  writeln("snapshot-remotes: " ~ snapshotRemotes.join(","));
  foreach (i, w; spec.subapps) {
    auto deps = resolver.resolveDependencies(entries[i]);
    writeln(format("webapp %s: app=%s path=%s deps=%d", w.id, entries[i], w.path, deps.length));
    foreach (j, dep; deps) {
      string kind;
      if (cast(Artifact) dep !is null) {
        kind = "gav";
      } else if (cast(LocalFile) dep !is null) {
        kind = "local";
      } else if (cast(RemoteFile) dep !is null) {
        kind = "http";
      } else {
        kind = "other";
      }
      writeln(format("  dep %d: %s %s -> %s", j + 1, kind, dep.raw,
          resolver.dependencyPath(dep)));
    }
  }
  return 0;
}

/**
 * 主类只对 java（jar/gav-jar/解压目录）目标有意义：war 跑引擎入口 main
 * （用 [app] engine 选入口 main），native（tar.gz）跑 [app] exec。这两种目标上给出
 * --main 或 [app] main 时告警忽略，不静默吞掉。
 */
private void warnIgnoredMain(BootArgs opts, bool specMode, LaunchSpec spec, string kind) {
  if (opts.quiet) {
    return;
  }
  if (opts.hasMain) {
    stderr.writeln("Warning: --main is for jar targets, ignored for " ~ kind ~ " targets.");
  }
  if (specMode && spec.main.length > 0) {
    stderr.writeln("Warning: [app] main is for java targets, ignored for " ~ kind
        ~ " targets.");
  }
}

/**
 * info 子命令：依赖准备完成后输出结构化信息（target/entry/落盘路径/main/每个依赖
 * 的来源、本地路径与体积/仓库位置），供审计与 IDE/CI 集成。输出为稳定的
 * "key: value" 文本（含 main 来源 cli/spec/manifest/none）；依赖以
 * "dep <n>: ..." 行给出，可直接 grep。
 */
private int printInfo(BootArgs opts, Resolver resolver, string appPath,
    Archive[] deps, MainClass mainClass, bool specMode, LaunchSpec spec,
    string nativeArchive = "", string nativeRoot = "") {
  import std.conv : to;
  import std.file : getSize, isDir;
  import std.format : format;

  import jstart.archive : Artifact, LocalFile, RemoteFile;

  string type;
  if (nativeArchive.length) {
    type = "native";
  } else if (isDir(appPath)) {
    type = "dir";
  } else if (appPath.endsWith(".war")) {
    type = "war";
  } else if (appPath.endsWith(".jar")) {
    type = "jar";
  } else {
    type = "file";
  }

  writeln("target: " ~ opts.target);
  writeln("entry: " ~ (specMode ? spec.entry : opts.target));
  writeln("app: " ~ appPath);
  writeln("type: " ~ type);
  writeln("main: " ~ (mainClass.name.length ? mainClass.name : "none"));
  writeln("main source: " ~ sourceName(mainClass.source));
  if (nativeArchive.length) {
    writeln("archive: " ~ nativeArchive);
    writeln("root: " ~ nativeRoot);
  }
  writeln("local: " ~ resolver.local.base);
  writeln("snapshots: " ~ resolver.local.snapshotBase);
  string[] remotes;
  foreach (r; resolver.remotes) {
    remotes ~= r.base;
  }
  writeln("remotes: " ~ remotes.join(","));
  string[] snapshotRemotes;
  foreach (r; resolver.snapshotRemotes) {
    snapshotRemotes ~= r.base;
  }
  writeln("snapshot-remotes: " ~ snapshotRemotes.join(","));
  writeln("deps: " ~ deps.length.to!string);
  foreach (i, dep; deps) {
    string kind;
    if (cast(Artifact) dep !is null) {
      kind = "gav";
    } else if (cast(LocalFile) dep !is null) {
      kind = "local";
    } else if (cast(RemoteFile) dep !is null) {
      kind = "http";
    } else {
      kind = "other";
    }
    auto path = resolver.dependencyPath(dep);
    auto size = 0L;
    try {
      size = getSize(path);
    } catch (Exception e) {
      size = -1;
    }
    writeln(format("dep %d: %s %s -> %s (%d bytes)", i + 1, kind, dep.raw,
        path, size));
  }
  return 0;
}

/**
 * 纯文本依赖清单已不支持：本地文件 target 只接受 jar/war（解压目录/launch spec
 * 由调用方各自处理）。返回拒绝消息，空串表示放行。
 */
/// --base 优先，其次 launch spec [app] base，都没有则用组件默认 base。
private string baseOption(BootArgs opts, LaunchSpec spec) {
  return opts.base.length ? opts.base : spec.base;
}

/**
 * 运行前准备 pid 文件：固定为 <base>/app.pid（base 由 --base/--instance/[app] base
 * 决定，见 jstart.base）。实例身份 = 组件 + base，参数不参与。
 *
 * 若文件指向一个真实存在（且 start 时间匹配，排除 pid 复用）的进程，说明这个 base
 * 上已经有实例在跑：报错不启动（除非 --force）；fatal 置 true 由调用方退出。
 *
 * 文件在准备阶段就写入（并发启动会被拒绝，而不是等到依赖下载完才发现），
 * 启动失败或应用退出后由调用方删除。
 */
private string preparePidFile(BootArgs opts, string base, string app, out bool fatal) {
  fatal = false;
  auto path = pidFilePath(base);
  if (path.length == 0) {
    if (!opts.quiet) {
      stderr.writeln("Warning: no base for pid files; pass --base=<dir> to keep one.");
    }
    return "";
  }
  PidInfo info;
  if (readPidFile(path, info) && processAlive(info.pid)) {
    auto start = processStartTime(info.pid);
    auto recycled = info.start.length && start.length && info.start != start;
    if (!recycled) {
      if (!opts.force) {
        stderr.writeln("Already running: pid " ~ to!string(info.pid)
            ~ (info.app.length ? " (" ~ info.app ~ ")" : "") ~ ".");
        stderr.writeln("Pid file: " ~ path ~ "; stop it with `jstart stop " ~ opts.target
            ~ "`, start another copy with its own `--base=<dir>`/--instance=<name>`"
            ~ ", or override with --force.");
        fatal = true;
        return "";
      }
      if (!opts.quiet) {
        stderr.writeln("Warning: pid " ~ to!string(info.pid) ~ " is still running; overwriting "
            ~ path ~ " (--force).");
      }
    }
  }
  string err;
  if (!writePidFile(path, opts.target, app, err)) {
    stderr.writeln("Cannot write pid file " ~ path ~ ": " ~ err);
    fatal = true;
    return "";
  }
  if (showProgress(opts)) {
    writeln("Pid file " ~ path ~ " (pid " ~ to!string(currentPid()) ~ ")");
  }
  return path;
}

/**
 * Remove the pid file after the launcher returns. A successful exec never
 * returns (the process becomes the application), so this only runs when the
 * launch failed or the application already exited.
 */
private void removePidOnExit(string pidPath) {
  if (pidPath.length) {
    removePidFile(pidPath);
  }
}

private string plainTargetReject(BootArgs opts) {
  auto t = expandLocalPath(opts.target);
  if (!exists(t) || !isFile(t) || t.endsWith(".jar") || t.endsWith(".war")
      || isNativeTarget(t)) {
    return ""; // gav/http/目录/native 发行包等非本地普通文件 target 放行
  }
  return "Unsupported target " ~ opts.target ~ ": plain text dependency lists are no "
    ~ "longer supported. Use a jar/war/exploded-dir target, or write a launch spec "
    ~ "(.jstart) declaring [app] main and entry.";
}

/**
 * Read a launch spec from its local file. Only `.jstart` targets are
 * specs (local paths, or http(s) urls already downloaded to specPath);
 * anything else returns false so the caller falls through to the plain
 * jar/war/gav/url flow. Parse warnings are printed unless quiet.
 */
private bool tryLoadSpec(BootArgs opts, string specPath, out LaunchSpec spec) {
  if (!isSpecFile(opts.target)) {
    return false;
  }
  if (!exists(specPath) || !isFile(specPath)) {
    return false;
  }
  string content;
  try {
    content = readText(specPath); // 二进制文件按文本读取会抛异常
  } catch (Exception e) {
    return false;
  }
  string[] warnings;
  spec = parseLaunchSpec(content, warnings);
  if (!opts.quiet) {
    foreach (w; warnings) {
      stderr.writeln("Warning: " ~ w);
    }
  }
  return true;
}

/** chdir before exec; POSIX only, Windows reports and keeps the cwd. */
private bool changeDir(string dir) {
  version (Posix) {
    import std.string : toStringz;
    import core.sys.posix.unistd : chdir;

    return chdir(dir.toStringz) == 0;
  } else version (Windows) {
    stderr.writeln("Warning: working_dir is not supported on Windows yet: " ~ dir);
    return true;
  }
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
  // launch spec：target 必须是本地 .jstart 文件，entry 必须是本地 jar/war/目录
  // （repo 是离线整合，不做联网下载，http(s) spec 在此处先行拒绝）。
  LaunchSpec spec;
  auto specMode = tryLoadSpec(opts, target, spec);
  if (specMode) {
    auto invalid = validateLaunchSpec(spec);
    if (invalid.length > 0) {
      stderr.writeln(invalid);
      return 1;
    }
  }
  if (specMode && spec.subapps.length == 0 && spec.entry.length == 0) {
    stderr.writeln("Missing entry in launch spec: " ~ opts.target);
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
  auto resolver = new Resolver(localRepo, [], showProgress(opts), opts.quiet, opts.offline);
  Archive[] deps;
  if (specMode && spec.subapps.length > 0) {
    // 多应用：逐 webapp 整合依赖（[deps] 与 [subapp] 段互斥，各 webapp 用自身 war 清单）。
    foreach (w; spec.subapps) {
      auto entry = expandLocalPath(w.entry);
      if (!exists(entry) || (!isFile(entry) && !isDir(entry))) {
        stderr.writeln("repo: [subapp " ~ w.id
            ~ "] entry must be a local file or directory: " ~ w.entry);
        return 1;
      }
      deps ~= resolver.resolveDependencies(entry);
    }
  } else if (specMode) {
    auto entry = expandLocalPath(spec.entry);
    if (!exists(entry) || (!isFile(entry) && !isDir(entry))) {
      stderr.writeln("repo: launch spec entry must be a local file or directory: " ~ spec.entry);
      return 1;
    }
    deps = spec.hasDeps ? resolver.parseDependencyText(spec.deps.join("\n"))
      : resolver.resolveDependencies(entry);
  } else {
    auto reject = plainTargetReject(opts);
    if (reject.length > 0) {
      if (!opts.quiet) {
        stderr.writeln(reject);
      }
      return 1;
    }
    deps = resolver.resolveDependencies(target);
  }
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

/**
 * fetch 子命令：负责把目标取回本地并打印其路径。
 *
 * gav 目标从发行仓库（beangle native 仓库，maven2 布局）取构件：若本地存在基线
 * 版本且远端发布了 `<old>_<new>` 的 bsdiff 补丁，则下载补丁重建并校验目标 sha1；
 * 否则整包下载。补丁不存在是正常情况，不报错。
 *
 * http(s) url 直接下载并缓存到本地仓库；本地文件原样返回其绝对路径。
 */
private int runFetch(BootArgs opts) {
  auto target = opts.target.strip;
  auto isUrl = target.startsWith("http://") || target.startsWith("https://");
  if (targetGav(target).length == 0 && !isUrl && !exists(expandLocalPath(target))) {
    stderr.writeln("fetch expects a gav (e.g. "
        ~ "org.beangle:beangle-ems-portal:tar.gz:linux-amd64:4.20.14-SNAPSHOT), "
        ~ "an http(s) url or an existing local file.");
    return 2;
  }
  auto localRepo = new LocalRepo(opts.local);
  auto resolver = new Resolver(localRepo, remotesOf(opts), showProgress(opts),
      opts.quiet, opts.offline, snapshotRemotesOf(opts));
  auto path = fetchArtifact(opts, resolver, target);
  if (path.length == 0) {
    return 1;
  }
  writeln(path);
  return 0;
}

// ------------------------------------------------------------------ native

/**
 * 取回一个文件目标：gav 走发行仓库逻辑（含增量补丁，即 fetch 的核心），
 * http(s) url 下载并按主机路径缓存到本地仓库，本地文件返回绝对路径。
 */
private string fetchArtifact(BootArgs opts, Resolver resolver, string target) {
  auto gav = targetGav(target);
  if (gav.length) {
    auto r = fetchDist(gav, opts.from, opts.remote, opts.local, showProgress(opts), "",
        opts.offline);
    return r.ok ? r.path : "";
  }
  return resolver.fetchTarget(target);
}

/// 远程仓库列表：`--offline` 为空（只用本地仓库），否则按 `--remote` 解析。
private RemoteRepo[] remotesOf(BootArgs opts) {
  return opts.offline ? [] : buildRemotes(opts.remote);
}

/**
 * SNAPSHOT 解析的上游：只取 `--snapshot-remote`，**不**兜到 `--remote`；不追加 Central、
 * 不给默认镜像（见 `jstart.repo.buildSnapshotRemotes`）。为空时 SNAPSHOT 只用本地快照库
 * （本地命中即可用，本地缺失才报错）；`--offline` 一律为空。
 */
private RemoteRepo[] snapshotRemotesOf(BootArgs opts) {
  if (opts.offline) {
    return [];
  }
  return buildSnapshotRemotes(opts.snapshotRemote);
}

/// gav 目标的 artifactId（用于在解压树里找同名可执行文件）；非 gav 返回 ""。
private string nativeArtifactId(string target) {
  auto gav = targetGav(target);
  if (gav.length == 0) {
    return "";
  }
  try {
    return parseGav(gav, gav).artifactId;
  } catch (Exception e) {
    return "";
  }
}

/// 解压后找不到可执行文件时的诊断输出。
private void reportNativeExecMissing(string archive, string[] candidates, string hint) {
  stderr.writeln("Cannot find the executable in " ~ archive);
  auto shown = candidates.length > 5 ? candidates[0 .. 5] : candidates;
  foreach (c; shown) {
    stderr.writeln("  candidate: " ~ c);
  }
  if (hint.length) {
    stderr.writeln("[app] exec = " ~ hint ~ " does not exist in the extracted tree.");
  } else {
    stderr.writeln(
        "Declare it in a launch spec: [app] exec = <path relative to the extraction root>.");
  }
}

/**
 * run 的 native 分支：可执行文件已从 tar.gz 解压出来，直接 exec 它。
 *
 * native 目标没有 JVM，也就没有独立的"运行时参数"：[args] 段与命令行参数一律
 * 按顺序跟在可执行文件之后（-D/-X 也不例外）；[runtime] 段与 [app] runtime 对
 * native 无意义，给出时告警忽略。classpath 对 native 无意义，报错退出。
 */
private int runNative(BootArgs opts, Resolver resolver, string execPath, Archive[] deps,
    bool specMode, LaunchSpec spec, string archive, string root) {
  if (opts.command == "classpath") {
    stderr.writeln(
        "classpath needs a jar/war target; use resolve to get the native executable path");
    return 2;
  }
  if (opts.command == "info") {
    return printInfo(opts, resolver, execPath, deps, MainClass.init, specMode, spec, archive,
        root);
  }
  warnIgnoredMain(opts, specMode, spec, "native (tar.gz)");
  if (specMode && spec.runtimeOptions.length > 0 && !opts.quiet) {
    stderr.writeln(
        "Warning: [runtime] options are for java targets, ignored for native (tar.gz) targets.");
  }
  if (specMode && spec.runtime.length > 0 && !opts.quiet) {
    stderr.writeln(
        "Warning: [app] runtime is ignored for native (tar.gz) targets, use [app] exec.");
  }
  string[] appArgs = specMode ? spec.args.dup : null;
  appArgs ~= opts.rest;
  if (!opts.print && specMode && spec.workingDir.length > 0) {
    auto dir = expandLocalPath(spec.workingDir);
    if (!changeDir(dir)) {
      stderr.writeln("Cannot chdir to " ~ dir);
      return 1;
    }
  }
  auto cmd = [execPath] ~ appArgs;
  if (opts.print) {
    return printCommand(cmd);
  }
  return runNativeApp(execPath, appArgs, showProgress(opts));
}
