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
import std.file : dirEntries, exists, isDir, isFile, mkdirRecurse, readText, remove,
  SpanMode;
import std.path : buildPath;
import std.stdio : stderr, writeln;
import std.string : startsWith, strip;

import jstart.archive : Archive, expandLocalPath, parseGav;
import jstart.base : PidInfo, currentPid, nativeDirName, pidFilePath, processAlive,
  processStartTime, readPidFile, removePidFile, resolveBase, stopApplication, stopNotRunning,
  writePidFile;
import jstart.distrepo : fetchDist;
import jstart.engine : appendEngineDeps, defaultEngineDeps, engineMainClass, expandEngineDeps,
  parseEngineSel, scanEngineArgs, warDocBaseDir, warDocBaseName;
import jstart.launcher : printCommand, printJavaCommand, runJarApp, runNativeApp;
import jstart.mainclass : MainClass, MainSource, isPlausibleMainClass, pickMainClass,
  sourceName;
import jstart.native : extractTarGz, findExecutable, isNativeTarget, targetGav;
import jstart.repo : LocalRepo, RemoteRepo, buildRemotes;
import jstart.resolver : Resolver;
import jstart.spec : LaunchSpec, isSpecFile, parseLaunchSpec;
import jstart.zipfile : explodeZip;

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
  bool preferWar;
  /// --print: 只打印将要执行的命令，不 exec。
  bool print;
  /// 并行下载并发数（--jobs），1 = 串行。
  int jobs = 10;
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
  writeln("      becomes the runtime itself (java for jar targets; war targets");
  writeln("      run with the built-in tomcat engine, see docs/war-engine.md;");
  writeln("      tar.gz targets are extracted and their executable is run).");
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
  writeln("  java 目标的主类按 --main > launch spec [app] main > jar 内 MANIFEST.MF");
  writeln("  Main-Class 的顺序确定（解压目录没有 manifest，只能靠前两者）。");
  writeln("  tar.gz（native）目标：取发行包（同 fetch，gav 时含增量补丁）后解压到");
  writeln("  <base>/app（base = <base 根>/<组件键>，根默认 /var/tmp/jstart），");
  writeln("  exec 解压出的可执行文件，[args]/命令行参数按序附加在其后；resolve 输出该");
  writeln("  可执行文件路径，可执行文件位置用 launch spec [app] exec= 指定。");
  writeln("  base：组件的运行基目录（pid 文件、native 解压、war 爆炸都在其中）。一个组件");
  writeln("  的一个 base 只能跑一个实例——跑多个副本请给每个副本不同的 --base/--instance；");
  writeln("  参数不参与实例身份，因此 run/stop 不需要给同样的参数。");
  writeln("");
  writeln("options:");
  writeln("  --local=<dir>    local repository (default ~/.m2/repository)");
  writeln("  --source=<dir>   source repository for the repo command");
  writeln("                   (default ~/.m2/repository, must differ from --local)");
  writeln("  --remote=<urls>  comma separated remote repositories");
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
  writeln("  --preferwar      for gav targets, prefer the war packaging");
  writeln("  --print          run only: print the command to execute (no exec)");
  writeln("  --jobs=N         parallel dependency downloads (default 10, 1 = serial)");
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
  auto remotes = buildRemotes(opts.remote);
  auto resolver = new Resolver(localRepo, remotes, !opts.quiet, opts.preferWar);

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
  if (specMode && spec.entry.length == 0) {
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

  // native（GraalVM tar.gz）目标：取包 -> 解压 -> 定位可执行文件，后面直接
  // exec 它（没有 JVM，也没有单独的运行时）。
  auto target = specMode ? spec.entry : opts.target;
  auto nativeMode = isNativeTarget(target);
  string nativeArchive;
  string nativeRoot;
  string appPath;
  // base：组件的运行基目录（pid 文件、native 解压、war 爆炸都在其中）。run 需要，
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
    auto extracted = extractTarGz(nativeArchive, !opts.quiet, false, extractDir);
    if (extracted.ok) {
      appPath = findExecutable(extracted.dir, execHint, artifactId, candidates);
    }
    if (appPath.length == 0 && extracted.ok && extracted.reused) {
      // 复用的解压目录不完整/被改动：强制重解一次
      extracted = extractTarGz(nativeArchive, !opts.quiet, true, extractDir);
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
  if (specMode && !appPath.endsWith(".war")
      && (spec.engine.length > 0 || spec.hasEngineDeps) && !opts.quiet) {
    stderr.writeln("Warning: [app] engine / [engine] applies to war targets only, ignored.");
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
  if (appPath.endsWith(".war")) {
    if (!opts.quiet && (opts.hasMain || (specMode && spec.main.length > 0))) {
      warnIgnoredMain(opts, specMode, spec, "war");
      stderr.writeln("Note: a war runs the engine's bootstrap class; "
          ~ "pick the engine with [app] engine (see docs/war-engine.md).");
    }
    return runWar(opts, resolver, appPath, deps, specMode, spec, base);
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
  return runJarApp(classpath, mainClass.name, runtimeOptions, appArgs, !opts.quiet, runtimeCmd);
}

/**
 * run 的 war 引擎分支：把 war 爆炸到 <base>/webapps/<name>，用应用 classpath +
 * 引擎依赖 exec 引擎 Bootstrap（进程仍变为 java，无父子等待）。
 *
 * - 引擎选择：launch spec [app] engine（war 缺省 tomcat；jar/其它运行时忽略）；
 *   tomcat 可带版本后缀 tomcat-<版本>，无后缀用内置默认版本；
 * - 引擎依赖：[engine] 段逐行罗列（存在即为准，不依赖内置行；行内可用
 *   {tomcat.version}/{sas.version} 占位符引用内置版本），缺省回退 tomcat
 *   内置默认（等价 sas.sh 的三个 download 行，engine = tomcat-<版本> 时用指定
 *   版本重钉两个 tomcat-embed jar）；undertow 依赖较多，须显式罗列；
 * - base 就是组件的 base（--base/--instance/[app] base）：引擎的 --base 也用它，
 *   爆炸到 <base>/webapps/<name>，pid 文件是 <base>/app.pid -- 一个 base 一个实例；
 * - --path= 被"读取"用于爆炸布局（最后一次出现生效，与引擎 CmdOptions 一致），之后
 *   仍原样转发给引擎；[args] 里的 --base= 不再作为 base（会被丢弃，避免与注入的
 *   --base=<base> 冲突），--port 等参数不读取、直接透传；
 * - 爆炸目录每次运行前重建（引擎关闭时会自行删除 docBase，与 sas.sh 的 rm -rf 语义一致）。
 */
private int runWar(BootArgs opts, Resolver resolver, string warPath,
    Archive[] appDeps, bool specMode, LaunchSpec spec, string base) {
  // 引擎选择：war 缺省 tomcat；tomcat 后可带版本（tomcat-11.0.24），无后缀或
  // 非 tomcat 引擎用内置默认版本。
  auto engineSel = specMode && spec.engine.length > 0 ? spec.engine : "tomcat";
  string engineName;
  string engineVersion;
  string engineMain;
  try {
    auto sel = parseEngineSel(engineSel);
    engineName = sel.name;
    engineVersion = sel.ver;
    engineMain = engineMainClass(engineName);
  } catch (Exception e) {
    stderr.writeln(e.msg);
    return 1;
  }

  // 引擎依赖：[engine] 段罗列为准（占位符先展开）；没有则用内置默认目录
  // （tomcat 支持 engine = tomcat-<版本> 重钉内置 embed jar）。
  Archive[] engineDeps;
  if (specMode && spec.hasEngineDeps) {
    auto lines = spec.engineDeps.dup;
    foreach (i, line; lines) {
      lines[i] = expandEngineDeps(line, engineVersion);
    }
    engineDeps = resolver.parseDependencyText(lines.join("\n"));
  } else {
    try {
      engineDeps = defaultEngineDeps(engineName, engineVersion);
    } catch (Exception e) {
      stderr.writeln(e.msg);
      return 1;
    }
  }
  auto merged = appendEngineDeps(appDeps, engineDeps);
  auto missing = resolver.ensureDependencies(merged, opts.jobs);
  if (missing.length > 0) {
    stderr.writeln("Missing: " ~ missing.join(","));
    return 1;
  }

  // 运行时参数与 app args 拆分（与 jar 分支一致）。
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

  // --path= 例外读取：仅用于决定爆炸位置，参数本身原样转发。--base 已是 jstart
  // 选项（不再从 [args] 里读；[args] 里的 --base 在下面被丢弃，避免与注入的
  // --base=<base> 冲突）。
  string ctxPath;
  string ignoredBase;
  scanEngineArgs(appArgs, ctxPath, ignoredBase);
  auto name = warDocBaseName(ctxPath);
  if (name.length == 0) {
    stderr.writeln("Unsafe context path for war explosion: --path=" ~ ctxPath);
    return 1;
  }
  auto docBase = warDocBaseDir(base, name);

  if (!opts.quiet) {
    writeln("Exploding " ~ warPath ~ " -> " ~ docBase);
  }
  rmTree(docBase);
  mkdirRecurse(docBase);
  auto extracted = explodeZip(warPath, docBase);
  if (extracted == 0) {
    stderr.writeln("Cannot explode " ~ warPath ~ " into " ~ docBase);
    return 1;
  }
  // 引擎（sas Server.Config.guessDocBase）会探测 classpath 上的目录资源；war
  // 没有 WEB-INF/classes 时补一个空目录，避免 getResource("") 为 null。
  auto classesDir = docBase ~ "/WEB-INF/classes";
  if (!exists(classesDir)) {
    mkdirRecurse(classesDir);
  }

  auto classpath = resolver.buildClasspath(docBase, merged);
  auto runtimeCmd = specMode && spec.runtime.length > 0 ? expandLocalPath(spec.runtime) : "";
  // --base 已消费（决定爆炸位置）：不再重复转发，统一放到 --base=<最终值>。
  string[] restArgs;
  foreach (a; appArgs) {
    if (!a.startsWith("--base=")) {
      restArgs ~= a;
    }
  }
  auto engineArgs = ["--base=" ~ base] ~ restArgs;
  if (opts.print) {
    return printJavaCommand(classpath, engineMain, runtimeOptions, engineArgs, runtimeCmd);
  }
  return runJarApp(classpath, engineMain, runtimeOptions, engineArgs, !opts.quiet, runtimeCmd);
}

/** 递归删除目录/文件（爆炸前清理历史残留）。 */
private void rmTree(string path) {
  if (!exists(path)) {
    return;
  }
  if (isDir(path)) {
    foreach (e; dirEntries(path, SpanMode.shallow)) {
      rmTree(e.name);
    }
  }
  remove(path);
}

/**
 * 主类只对 java（jar/gav-jar/解压目录）目标有意义：war 跑引擎的 Bootstrap 类
 * （用 [app] engine 选引擎），native（tar.gz）跑 [app] exec。这两种目标上给出
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
  if (!opts.quiet) {
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
  if (specMode && spec.entry.length == 0) {
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
  auto resolver = new Resolver(localRepo, [], !opts.quiet);
  Archive[] deps;
  if (specMode) {
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
  auto remotes = buildRemotes(opts.remote);
  auto resolver = new Resolver(localRepo, remotes, !opts.quiet, opts.preferWar);
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
    auto r = fetchDist(gav, opts.from, opts.remote, opts.local, !opts.quiet);
    return r.ok ? r.path : "";
  }
  return resolver.fetchTarget(target);
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
  return runNativeApp(execPath, appArgs, !opts.quiet);
}
