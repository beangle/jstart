/**
 * Resolves an application target (jar, war, exploded directory, gav or url),
 * prepares its dependency environment and assembles the launch classpath.
 *
 * The dependency description file inside a beangle prepared jar/war is:
 *
 *   jar: META-INF/beangle/dependencies
 *   war: WEB-INF/classes/META-INF/beangle/dependencies
 */
module jstart.resolver;

import std.algorithm : canFind, endsWith, sort;
import std.array : join, split;
import std.conv : to;
import std.file : dirEntries, exists, isDir, isFile, readText, remove, SpanMode;
import std.parallelism : TaskPool;
import std.path : absolutePath, baseName, pathSeparator;
import std.process : environment;
import std.range : iota;
import std.stdio : stderr, writeln;
import std.string : indexOf, startsWith, strip;

import jstart.archive : Archive, Artifact, LocalFile, RemoteFile,
  expandLocalPath, parseArchive, parseGav;
import jstart.http : downloadFile, downloadFileSmart;
import jstart.repo : LocalRepo, RemoteRepo, verifySha1;
import jstart.snapshot : fetchSnapshot, localSnapshotFile;
import jstart.zipfile : manifestMainClass, readZipEntry;

/** Whether a file name looks like a jar/war archive. */
private bool isAppFile(string path) {
  return path.endsWith(".jar") || path.endsWith(".war");
}

/** Decode bytes returned by the zip reader as utf-8 text. */
private string toText(ubyte[] data) {
  return cast(string) data.idup;
}

/**
 * Resolves applications against a local and several remote repositories.
 */
final class Resolver {
  LocalRepo local;
  /// 普通（正式版）构件与依赖的上游：`--remote` 的默认镜像与 Maven Central 兜底在此。
  RemoteRepo[] remotes;
  /**
     SNAPSHOT 的上游：**不**套用 `--remote` 的默认镜像与 Central 兜底，只用调用方显式
     给出的列表（bas 传 `<SnapshotRepo remote>`）；为空表示不代理，只用本地仓库。
     与 [[remotes]] 分开，是因为开发版一般来自专用仓库，兜到公共镜像没有意义。
   */
  RemoteRepo[] snapshotRemotes;
  /// 过程细节（解析/下载/命中本地）是否输出，由调用方决定。
  bool verbose;
  /// 静默：连错误也只在退出码里体现（--quiet）。
  bool quiet;
  /// 离线：只用本地仓库，http(s) 目标/远程文件依赖不下载（--offline）。
  bool offline;
  /// Snapshot 构件解析到的本地时间戳文件（raw -> path）。
  string[string] snapshotFiles;

  this(LocalRepo local, RemoteRepo[] remotes, bool verbose = true,
      bool quiet = false, bool offline = false, RemoteRepo[] snapshotRemotes = []) {
    this.local = local;
    this.remotes = remotes;
    this.verbose = verbose;
    this.quiet = quiet;
    this.offline = offline;
    this.snapshotRemotes = snapshotRemotes;
  }

  // ------------------------------------------------------------- target

  /**
     * Fetch the application target and return its absolute local path.
     * Supports local files/directories, gav strings, gav:// urls and
     * http(s) urls (the latter cached under the local repository).
     * Returns "" when the target cannot be obtained.
     */
  string fetchTarget(string spec) {
    auto s = spec.strip;
    if (s.length == 0) {
      return "";
    }
    if (s.startsWith("http://") || s.startsWith("https://")) {
      if (offline) {
        error("Offline: cannot download " ~ s);
        return "";
      }
      auto rf = new RemoteFile(s, s);
      auto target = remoteLocalPath(rf);
      if (!exists(target)) {
        if (verbose) {
          writeln("Downloading " ~ s);
        }
        if (!downloadFile(s, target, verbose, baseName(target))) {
          error("Cannot download " ~ s);
          return "";
        }
      }
      return target;
    }
    if (s.startsWith("gav://")) {
      return fetchGav(parseGav(s, s["gav://".length .. $]));
    }
    if (s.canFind(":") && !s.canFind("/") && !s.canFind("\\")) {
      return fetchGav(parseGav(s, s));
    }
    auto p = expandLocalPath(s);
    if (exists(p) && (isFile(p) || isDir(p))) {
      return absolutePath(p);
    }
    error("Cannot find " ~ s);
    return "";
  }

  /** Download a gav artifact; SNAPSHOT returns its timestamped file. */
  private string fetchGav(Artifact a) {
    string ts;
    if (!ensureArtifact(a, ts)) {
      error("Cannot download " ~ a.raw);
      return "";
    }
    return rememberSnapshot(a, ts);
  }

  /// 记录 SNAPSHOT 命中的时间戳文件（classpath 用）并返回本地路径；非快照返回仓库布局路径。
  private string rememberSnapshot(Artifact a, string timestamped) {
    if (timestamped.length) {
      snapshotFiles[a.raw] = timestamped;
      return timestamped;
    }
    return local.filePath(a);
  }

  // ----------------------------------------------------- dependencies

  /**
     * Read the dependency description of the given application file or
     * directory: the description is embedded inside a jar/war (or lives at
     * the war layout path of an exploded directory). Only the explicit
     * lines inside the description are taken into account: jstart never
     * reads Maven POMs and performs no transitive dependency resolution,
     * so the application must list all of its runtime dependencies
     * (project constraint).
     */
  Archive[] resolveDependencies(string appPath) {
    string content;
    if (isFile(appPath)) {
      if (isAppFile(appPath)) {
        auto entry = appPath.endsWith(".war")
          ? "WEB-INF/classes/META-INF/beangle/dependencies" : "META-INF/beangle/dependencies";
        auto data = readZipEntry(appPath, entry);
        if (data is null && appPath.endsWith(".war")) {
          // fallback: a war packed like an executable jar
          data = readZipEntry(appPath, "META-INF/beangle/dependencies");
        }
        if (data is null) {
          if (verbose) {
            writeln("Cannot find " ~ entry ~ " inside " ~ appPath);
          }
          return [];
        }
        content = toText(data);
      } // 其它普通文件不再当作依赖清单读取（纯文本清单已不支持）
    } else if (isDir(appPath)) {
      auto nested = appPath ~ "/WEB-INF/classes/META-INF/beangle/dependencies";
      // isFile/isDir 底层是 std.file.getAttributes，对不存在（含中间目录缺失）的路径
      // 会抛 FileException，必须先 exists 守卫——目录里没有依赖清单是常态。
      if (exists(nested) && isFile(nested)) {
        content = readText(nested);
      }
    } else {
      return [];
    }
    return parseDependencyText(content);
  }

  /**
     * Parse dependency lines, skipping blanks and exact duplicates.
     * One line is one required dependency; no transitive expansion or
     * version mediation is applied. If a dependency is not written out in
     * the description, it will simply be reported Missing at runtime.
     */
  Archive[] parseDependencyText(string content) {
    Archive[] deps;
    bool[string] seen;
    foreach (lineRaw; content.split("\n")) {
      auto line = lineRaw.strip;
      if (line.length == 0) {
        continue;
      }
      Archive dep;
      try {
        dep = parseArchive(line);
      } catch (Exception e) {
        if (verbose) {
          writeln("Ignore " ~ e.msg);
        }
        continue;
      }
      if (dep !is null && !(dep.raw in seen)) {
        seen[dep.raw] = true;
        deps ~= dep;
      }
    }
    return deps;
  }

  /**
     * Ensure every dependency is present locally: downloads missing
     * artifacts and verifies sha1 when possible. Returns the raw
     * descriptions of unresolved dependencies.
     *
     * Dependencies are processed concurrently when jobs > 1 (default 10):
     * each one downloads through its own curl process into its own .part
     * file, so parallel connections are only limited by the remote host.
     * Set jobs to 1 for a strictly serial download.
     */
  string[] ensureDependencies(Archive[] deps, int jobs = 10) {
    snapshotFiles = null;
    auto snap = new string[deps.length];
    if (jobs > 1 && deps.length > 1) {
      auto results = new string[deps.length];
      auto pool = new TaskPool(cast(size_t) jobs);
      scope (exit) pool.stop();
      foreach (i; pool.parallel(iota(deps.length))) {
        string tsFile;
        results[i] = ensureOne(deps[i], tsFile) ? "" : deps[i].raw;
        snap[i] = tsFile;
      }
      string[] missing;
      foreach (raw; results) {
        if (raw.length) {
          missing ~= raw;
        }
      }
      foreach (i, dep; deps) {
        if (snap[i].length) {
          snapshotFiles[dep.raw] = snap[i];
        }
      }
      return missing;
    }
    string[] missing;
    foreach (i, dep; deps) {
      string tsFile;
      if (!ensureOne(dep, tsFile)) {
        missing ~= dep.raw;
      } else {
        snap[i] = tsFile;
      }
    }
    foreach (i, dep; deps) {
      if (snap[i].length) {
        snapshotFiles[dep.raw] = snap[i];
      }
    }
    return missing;
  }

  /// Ensure one dependency; true when it is present or downloaded.
  private bool ensureOne(Archive dep, out string snapshotPath) {
    snapshotPath = "";
    if (auto a = cast(Artifact) dep) {
      // SNAPSHOT 的最新构建解析（远端 latest/元数据 → 本地仓库）在 ensureArtifact 内
      return ensureArtifact(a, snapshotPath);
    } else if (auto lf = cast(LocalFile) dep) {
      auto ok = exists(lf.file);
      if (!ok && verbose) {
        writeln("Cannot find " ~ lf.file);
      }
      return ok;
    } else if (auto rf = cast(RemoteFile) dep) {
      return ensureRemoteFile(rf);
    }
    return true;
  }

  /** Ensure a remote file dependency is cached under the local repo. */
  private bool ensureRemoteFile(RemoteFile rf) {
    auto target = remoteLocalPath(rf);
    if (exists(target)) {
      return true;
    }
    if (offline) {
      error("Offline: cannot download " ~ rf.url);
      return false;
    }
    if (verbose) {
      writeln("Downloading " ~ rf.url);
    }
    if (downloadFileSmart(rf.url, target, verbose, baseName(target))) {
      return true;
    }
    error("Cannot download " ~ rf.url);
    return false;
  }

  /** Local cache path of a remote file, mirroring its host path. */
  string remoteLocalPath(RemoteFile rf) {
    auto u = rf.url;
    if (u.startsWith("https://")) {
      u = u["https://".length .. $];
    } else if (u.startsWith("http://")) {
      u = u["http://".length .. $];
    }
    auto q = u.indexOf("?");
    if (q >= 0) {
      u = u[0 .. q];
    }
    return local.base ~ "/" ~ u;
  }

  /**
     * Ensure a single artifact exists in the local repository.
     * Existing files are checked against their .sha1 companion; missing or
     * corrupted ones are downloaded by trying the remotes in order.
     *
     * SNAPSHOT 走 [[ensureSnapshot]]：只在快照上游（[[snapshotRemotes]]，来自
     * `--snapshot-remote`）与本地仓库范围内解析，**不会**兜到 [[remotes]]（`--remote`）
     * ——没配快照上游时本地命中即用、本地缺失才报错，开发版不会因为「没配快照上游」而
     * 跑去公共镜像。命中时间戳文件（或本地字面别名）时通过 snapshotPath 回传其绝对
     * 路径，供 classpath 与返回值使用。
     */
  bool ensureArtifact(Artifact a) {
    string ignored;
    return ensureArtifact(a, ignored);
  }

  bool ensureArtifact(Artifact a, out string snapshotPath) {
    snapshotPath = "";
    if (a.isSnapshot) {
      return ensureSnapshot(a, snapshotPath);
    }
    return ensurePlainArtifact(a);
  }

  /** 正式版构件的下载/校验。 */
  private bool ensurePlainArtifact(Artifact a) {
    auto file = local.filePath(a);
    auto sha1File = local.filePath(a.sha1);
    auto needDownload = !exists(file);

    if (exists(file) && !a.isSnapshot) {
      if (exists(sha1File)) {
        if (verifySha1(local, a)) {
          return true;
        }
        error("Error sha1 for " ~ a.raw ~ ",Remove it.");
        remove(file);
        remove(sha1File);
        needDownload = true;
        // 本地已命中且无 .sha1：直接接受，不发起网络补拉。
      }
    }

    if (needDownload) {
      if (offline) {
        error("Offline: missing " ~ a.raw);
        return false;
      }
      foreach (remote; remotes) {
        auto url = remote.base ~ a.layoutPath;
        logInfo("Downloading " ~ url);
        if (!downloadFileSmart(url, file, verbose, a.raw)) {
          continue;
        }
        // 下载后从同一远程复核 .sha1（SNAPSHOT 同样校验）；该远程无 .sha1
        // 时接受（verify aborted），与既有 release 语义一致。
        auto sha1Url = remote.base ~ a.sha1.layoutPath;
        if (downloadFile(sha1Url, sha1File, false, "")) {
          if (!verifySha1(local, a)) {
            error("Error sha1 for " ~ a.raw ~ ",Remove it.");
            remove(file);
            remove(sha1File);
            continue; // try the next remote
          }
        }
        return true;
      }
      error("Not found(" ~ to!string(remotes.length) ~ " mirrors):" ~ a.raw);
      return false;
    }
    return true;
  }

  // ----------------------------------------------------------- snapshot

  /**
     确保一个 SNAPSHOT 构件就位。快照上游只看 [[snapshotRemotes]]（来自
     `--snapshot-remote`，**不**兜到 `--remote`，也不含默认镜像与 Central）：

      - 配了上游：按上游顺序解析最新时间戳文件（实现见
        [[jstart.snapshot.fetchSnapshot]]：micdn 的 `latest` 头，或版本目录的
        `maven-metadata.xml`），落盘到本地仓库并复核 `.sha1`；解析不出或上游不可达时
        退回本地仓库里已有的时间戳文件（其次字面别名），不报错。
      - 没配上游：既不发任何请求也不报错，直接用本地仓库里已有的文件。
      - 没配上游且本地也没有该文件时才报错——需要拉取却没有任何地址可问。

     `--offline` 只是"不拉取"，语义等同"没配上游"，同样允许命中的本地快照文件。
   */
  private bool ensureSnapshot(Artifact a, out string snapshotPath) {
    snapshotPath = "";
    if (offline) {
      snapshotPath = localSnapshotFile(local, a, verbose);
      return snapshotPath.length > 0;
    }
    auto localPath = localSnapshotFile(local, a, verbose);
    if (snapshotRemotes.length == 0) {
      if (localPath.length == 0) {
        error("Cannot fetch SNAPSHOT " ~ a.raw ~ ": its version directory in the local"
            ~ " repository has no timestamped file and no snapshot upstream is"
            ~ " configured. Pass --snapshot-remote=<url>, or place the artifact in the"
            ~ " local repository and use --offline.");
        return false;
      }
      snapshotPath = localPath;
      return true;
    }
    snapshotPath = fetchSnapshot(local, snapshotRemotes, a, verbose).path;
    return snapshotPath.length > 0;
  }

  // --------------------------------------------------------- classpath

  /**
     * The launch classpath of the application: the app jar itself (or the
     * classes/lib entries of an exploded war directory) followed by every
     * resolved dependency. CLASSPATH_EXTRA/classpath_extra is prepended.
     */
  string buildClasspath(string appPath, Archive[] deps) {
    string[] paths;
    auto extra = environment.get("classpath_extra");
    if (extra.length == 0) {
      extra = environment.get("CLASSPATH_EXTRA");
    }
    if (extra.length) {
      paths ~= extra.split(pathSeparator);
    }
    // appPath 允许为空（引擎分支只要依赖 classpath）：isFile/isDir 对空串会抛
    // FileException（std.file.getAttributes），必须先守卫。
    if (appPath.length > 0) {
      if (isFile(appPath) && appPath.endsWith(".jar")) {
        paths ~= appPath;
      } else if (isDir(appPath)) {
        auto classes = appPath ~ "/WEB-INF/classes";
        if (exists(classes)) {
          paths ~= classes;
        }
        auto lib = appPath ~ "/WEB-INF/lib";
        if (exists(lib) && isDir(lib)) {
          string[] libs;
          foreach (e; dirEntries(lib, SpanMode.shallow)) {
            if (e.isFile && e.name.endsWith(".jar")) {
              libs ~= e.name;
            }
          }
          libs.sort;
          paths ~= libs;
        }
      }
    }
    foreach (dep; deps) {
      paths ~= dependencyPath(dep);
    }
    return paths.join(pathSeparator);
  }

  /**
     Classpath of a resolved dependency list only: no entry classes/libs and
     no CLASSPATH_EXTRA. The engine branch uses this for the engine jars
     (`--app-classpath-file` carries the application deps separately, and the
     webapp's own WEB-INF entries are added by the engine, which is the only
     side that knows the docBase).
   */
  string depsClasspath(Archive[] deps) {
    string[] paths;
    foreach (dep; deps) {
      paths ~= dependencyPath(dep);
    }
    return paths.join(pathSeparator);
  }

  /**
     * classpath 中一条依赖的本地路径：Artifact 命中本地仓库时间戳文件时返回
     * 该时间戳文件，否则为本地仓库布局路径；LocalFile/RemoteFile 返回各自落盘。
     */
  string dependencyPath(Archive dep) {
    if (auto a = cast(Artifact) dep) {
      return snapshotFiles.get(a.raw, local.filePath(a));
    } else if (auto lf = cast(LocalFile) dep) {
      return lf.file;
    } else if (auto rf = cast(RemoteFile) dep) {
      return remoteLocalPath(rf);
    }
    return dep.raw;
  }

  /** Main-Class of the target jar; "" when absent (e.g. wars or dirs). */
  string mainClassOf(string appPath) {
    if (isFile(appPath) && appPath.endsWith(".jar")) {
      return manifestMainClass(appPath);
    }
    return "";
  }

  private void logInfo(string msg) {
    if (verbose) {
      writeln(msg);
    }
  }

  private void error(string msg) {
    if (!quiet) {
      stderr.writeln(msg);
    }
  }
}
