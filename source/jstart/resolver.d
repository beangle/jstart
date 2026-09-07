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
  RemoteRepo[] remotes;
  /// Prefer war packaging when resolving a gav artifact.
  bool preferWar;
  bool verbose;
  /// Snapshot 构件解析到的本地时间戳文件（raw -> path）。
  string[string] snapshotFiles;

  this(LocalRepo local, RemoteRepo[] remotes, bool verbose = true, bool preferWar = false) {
    this.local = local;
    this.remotes = remotes;
    this.verbose = verbose;
    this.preferWar = preferWar;
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

  /** Download a gav artifact (and its war sibling when preferWar). */
  private string fetchGav(Artifact a) {
    if (preferWar && a.packaging == "jar") {
      auto war = a.withPackaging("war");
      if (ensureArtifact(war)) {
        return local.filePath(war);
      }
    }
    if (!ensureArtifact(a)) {
      error("Cannot download " ~ a.raw);
      return "";
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
      if (isFile(nested)) {
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
    bool ok;
    if (auto a = cast(Artifact) dep) {
      if (a.isSnapshot) {
        auto tsFile = local.snapshotPathOf(a);
        if (tsFile.length) {
          snapshotPath = tsFile;
          return true;
        }
      }
      ok = ensureArtifact(a);
    } else if (auto lf = cast(LocalFile) dep) {
      ok = exists(lf.file);
      if (!ok && verbose) {
        writeln("Cannot find " ~ lf.file);
      }
    } else if (auto rf = cast(RemoteFile) dep) {
      ok = ensureRemoteFile(rf);
    } else {
      ok = true;
    }
    return ok;
  }

  /** Ensure a remote file dependency is cached under the local repo. */
  private bool ensureRemoteFile(RemoteFile rf) {
    auto target = remoteLocalPath(rf);
    if (exists(target)) {
      return true;
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
     */
  bool ensureArtifact(Artifact a) {
    auto file = local.filePath(a);
    auto sha1File = local.filePath(a.sha1);
    auto needDownload = !exists(file);

    if (exists(file) && !a.isSnapshot) {
      if (exists(sha1File)) {
        if (verifySha1(local, a)) {
          return true;
        }
        logInfo("Error sha1 for " ~ a.raw ~ ",Remove it.");
        remove(file);
        remove(sha1File);
        needDownload = true;
        // 本地已命中且无 .sha1：直接接受，不发起网络补拉。
      }
    }

    if (needDownload) {
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
            logInfo("Error sha1 for " ~ a.raw ~ ",Remove it.");
            remove(file);
            remove(sha1File);
            continue; // try the next remote
          }
        }
        return true;
      }
      logInfo("Not found(" ~ to!string(remotes.length) ~ " mirrors):" ~ a.raw);
      return false;
    }
    return true;
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
    if (isFile(appPath) && appPath.endsWith(".jar")) {
      paths ~= appPath;
    } else if (isDir(appPath)) {
      auto classes = appPath ~ "/WEB-INF/classes";
      if (exists(classes)) {
        paths ~= classes;
      }
      auto lib = appPath ~ "/WEB-INF/lib";
      if (isDir(lib)) {
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
    foreach (dep; deps) {
      paths ~= dependencyPath(dep);
    }
    return paths.join(pathSeparator);
  }

  /**
     * classpath 中一条依赖的本地路径：Artifact 命中快照库时间戳文件时返回
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
    if (verbose) {
      stderr.writeln(msg);
    }
  }
}
