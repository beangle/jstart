/**
 * jstart - a lightweight jar/war booter written in D.
 *
 * It resolves a jar/war application, prepares the dependency environment by
 * downloading missing artifacts into the local maven repository, then
 * launches the application. Arguments such as --port=8080 are passed to the
 * application untouched.
 */
module app;

import std.algorithm : endsWith;
import std.array : join;
import std.file : dirEntries, exists, isDir, isFile, mkdirRecurse, readText, remove,
  SpanMode;
import std.path : buildPath;
import std.stdio : stderr, writeln;
import std.string : startsWith, strip;

import jstart.archive : Archive, expandLocalPath;
import jstart.engine : appendEngineDeps, defaultEngineDeps, defaultWarBase, engineMainClass,
  expandEngineDeps, parseEngineSel, scanEngineArgs, warDocBaseDir, warDocBaseName;
import jstart.launcher : printJavaCommand, runJarApp;
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
    } else if (r.target.length == 0 && (a == "resolve" || a == "classpath" || a == "info"
        || a == "run" || a == "repo")) {
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
  writeln("      Prepare dependencies then exec the runtime: the process");
  writeln("      becomes the runtime itself (java for jar targets; war targets");
  writeln("      run with the built-in tomcat engine, see docs/war-engine.md).");
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
  writeln("");
  writeln("target:");
  writeln("  /path/to/app.jar | app.war | exploded-war-dir");
  writeln("  /path/to/app.jstart                launch spec declaring main/entry/runtime/args");
  writeln("  group:artifact:version | gav://group:artifact:version");
  writeln("  http(s)://host/path/to/app.jar");
  writeln("  http(s)://host/path/to/app.jstart  remote launch spec (downloaded and parsed)");
  writeln("");
  writeln("  run 需要可启动的应用本体：jar/gav/url/解压目录，或写成 launch spec");
  writeln("  （.jstart，支持本地或 http(s)，见 docs/launch-spec.md）。本地文件 target 只接受");
  writeln("  jar/war/解压目录；纯文本依赖清单已不支持。");
  writeln("");
  writeln("options:");
  writeln("  --local=<dir>    local repository (default ~/.m2/repository)");
  writeln("  --source=<dir>   source repository for the repo command");
  writeln("                   (default ~/.m2/repository, must differ from --local)");
  writeln("  --remote=<urls>  comma separated remote repositories");
  writeln("  --preferwar      for gav targets, prefer the war packaging");
  writeln("  --print          run only: print the java command without executing");
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

  // --print 只对 run 有意义：打印将要执行的命令行（当前即 java）。
  if (opts.print && opts.command != "run") {
    stderr.writeln("--print is only supported by the run command");
    return 2;
  }

  if (opts.command == "repo") {
    return runRepo(opts);
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
  if (!specMode) {
    auto reject = plainTargetReject(opts);
    if (reject.length > 0) {
      stderr.writeln(reject);
      return 1;
    }
  }

  auto appPath = resolver.fetchTarget(specMode ? spec.entry : opts.target);
  if (appPath.length == 0) {
    return 1;
  }
  if (specMode && !appPath.endsWith(".war")
      && (spec.engine.length > 0 || spec.hasEngineDeps) && !opts.quiet) {
    stderr.writeln("Warning: [app] engine / [engine] applies to war targets only, ignored.");
  }
  Archive[] deps;
  if (specMode && spec.hasDeps) {
    // 显式 [deps] 段是唯一来源，不再回退读取 entry 内置依赖清单。
    deps = resolver.parseDependencyText(spec.deps.join("\n"));
  } else {
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

  auto manifestMain = resolver.mainClassOf(appPath);
  auto mainClass = specMode && spec.main.length > 0 ? spec.main : manifestMain;
  auto classpath = resolver.buildClasspath(appPath, deps);

  if (opts.command == "classpath") {
    auto main = mainClass.length ? mainClass : "none";
    writeln(main ~ "@" ~ classpath);
    return 0;
  }

  if (opts.command == "info") {
    return printInfo(opts, resolver, appPath, deps, mainClass, specMode, spec);
  }

  // command == "run"
  if (appPath.endsWith(".war")) {
    return runWar(opts, resolver, appPath, deps, specMode, spec);
  }
  if (mainClass.length == 0) {
    stderr.writeln("Cannot find Main-Class in MANIFEST.MF of " ~ appPath);
    stderr.writeln(
        "Launch a jar/gav/url target, or write a launch spec (.jstart) with");
    stderr.writeln("[app] main and entry to describe how to start (see docs/launch-spec.md).");
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
    return printJavaCommand(classpath, mainClass, runtimeOptions, appArgs, runtimeCmd);
  }
  return runJarApp(classpath, mainClass, runtimeOptions, appArgs, !opts.quiet, runtimeCmd);
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
 * - --path=/--base= 被"读取"用于爆炸布局（最后一次出现生效，与引擎 CmdOptions
 *   一致），之后仍原样转发给引擎；--port 等参数不读取、直接透传；
 * - 默认 base 为 ${TMPDIR:-/tmp}/jstart-sas；爆炸目录每次运行前重建（引擎关闭时
 *   会自行删除 docBase，与 sas.sh 的 rm -rf 语义一致）。
 */
private int runWar(BootArgs opts, Resolver resolver, string warPath,
    Archive[] appDeps, bool specMode, LaunchSpec spec) {
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

  // --path=/--base= 例外读取：仅用于决定爆炸位置，参数本身原样转发。
  string ctxPath;
  string base;
  scanEngineArgs(appArgs, ctxPath, base);
  if (base.length == 0) {
    base = defaultWarBase();
  }
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
 * info 子命令：依赖准备完成后输出结构化信息（target/entry/落盘路径/main/每个依赖
 * 的来源、本地路径与体积/仓库位置），供审计与 IDE/CI 集成。输出为稳定的
 * "key: value" 文本；依赖以 "dep <n>: ..." 行给出，可直接 grep。
 */
private int printInfo(BootArgs opts, Resolver resolver, string appPath,
    Archive[] deps, string mainClass, bool specMode, LaunchSpec spec) {
  import std.conv : to;
  import std.file : getSize, isDir;
  import std.format : format;

  import jstart.archive : Artifact, LocalFile, RemoteFile;

  string type;
  if (isDir(appPath)) {
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
  writeln("main: " ~ (mainClass.length ? mainClass : "none"));
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
private string plainTargetReject(BootArgs opts) {
  auto t = expandLocalPath(opts.target);
  if (!exists(t) || !isFile(t) || t.endsWith(".jar") || t.endsWith(".war")) {
    return ""; // gav/http/目录等非本地普通文件 target 放行
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
