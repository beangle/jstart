/**
 * Native distributions packed as .tar.gz (GraalVM native-image builds).
 *
 * A dist artifact such as
 *
 *   org.beangle:beangle-ems-portal:tar.gz:linux-amd64:4.20.14-SNAPSHOT
 *
 * is a compressed tar tree, conventionally laid out as
 *
 *   <name>/bin/<executable> + <name>/lib/...
 *
 * jstart extracts it into the component's base (<base>/app, see jstart.base;
 * the artifact's own directory is never used) and execs the executable,
 * appending the declared/CLI arguments -- there is no JVM and no runtime.
 *
 * Like downloads (curl) and patch compression (gzip/bzip2), extraction is
 * delegated to the host `tar` command instead of linking a D tar library.
 */
module jstart.native;

import std.algorithm : canFind, sort;
import std.conv : to;
import std.file : dirEntries, exists, getSize, getTimes, isDir, isFile, mkdirRecurse,
  readText, remove, rename, SpanMode, write;
import std.path : baseName, buildPath, dirName;
import std.process : spawnProcess, wait;
import std.string : endsWith, indexOf, replace, startsWith, strip, toLower;
import std.stdio : File, stderr, writeln;

import jstart.archive : parseGav;

/// Pid used to name private temporary directories (0 on non-POSIX systems).
private long currentPid() {
  version (Posix) {
    import core.sys.posix.unistd : getpid;

    return getpid();
  } else {
    return 0;
  }
}

/// Suffixes accepted as a compressed tar distribution.
immutable string[] tarGzSuffixes = [".tar.gz", ".tgz"];

/// Whether a gav packaging denotes a compressed tar distribution.
bool isTarGzPackaging(string packaging) {
  foreach (ext; ["tar.gz", "tgz"]) {
    if (packaging == ext) {
      return true;
    }
  }
  return false;
}

/**
 * The gav text when the target is a gav (optionally `gav://` prefixed), or ""
 * for local paths and urls.
 */
string targetGav(string target) {
  auto s = target.strip;
  if (s.startsWith("http://") || s.startsWith("https://")) {
    return "";
  }
  if (s.startsWith("gav://")) {
    s = s["gav://".length .. $];
  }
  if (s.canFind(":") && !s.canFind("/") && !s.canFind("\\")) {
    return s;
  }
  return "";
}

/**
 * Whether the target is a native distribution: a tar.gz/tgz gav, or a local
 * path / url ending in .tar.gz or .tgz.
 */
bool isNativeTarget(string target) {
  auto gav = targetGav(target);
  if (gav.length) {
    try {
      return isTarGzPackaging(parseGav(gav, gav).packaging);
    } catch (Exception e) {
      return false;
    }
  }
  auto s = target.strip;
  auto q = s.indexOf("?");
  if (q >= 0) {
    s = s[0 .. q];
  }
  s = s.toLower;
  foreach (ext; tarGzSuffixes) {
    if (s.endsWith(ext)) {
      return true;
    }
  }
  return false;
}

/// Marker file inside the extraction directory recording the archive stamp
/// (inside, so that a directory and its stamp always appear atomically).
private enum stampFileName = ".jstart.stamp";

/// Outcome of an extraction attempt.
struct Extraction {
  bool ok;
  /// Directory the archive was extracted into ("" on failure).
  string dir;
  /// The directory was already extracted from this archive and was reused.
  bool reused;
}

/**
 * Extract `archive` into the directory `dir` (a native run passes
 * <base>/app, see jstart.base). There is deliberately no "beside the archive"
 * fallback, so a native run never writes into the maven repository or a user
 * data directory.
 *
 * The extraction is cached: when the marker matches the archive size/mtime the
 * existing directory is reused. `force` re-extracts regardless (used when a
 * cached extraction turns out to be unusable).
 *
 * Concurrent extractions into the same directory (two `run`s sharing a base,
 * or a stale partial tree) are safe: each extracts into its own temporary
 * directory and then atomically renames it into place; whoever loses the race
 * simply reuses the winner's directory.
 */
Extraction extractTarGz(string archive, bool verbose, bool force, string dir) {
  try {
    return extractTarGzImpl(archive, verbose, force, dir);
  } catch (Throwable t) {
    // 解压属于"准备阶段"：任何意外都不该让启动器带着堆栈崩掉
    stderr.writeln("Cannot extract " ~ archive ~ ": " ~ t.msg);
    Extraction r;
    return r;
  }
}

/// Body of extractTarGz (see there for the semantics).
private Extraction extractTarGzImpl(string archive, bool verbose, bool force, string destDir) {
  Extraction r;
  if (!exists(archive) || !isFile(archive)) {
    stderr.writeln("Cannot extract " ~ archive ~ ": not a file");
    return r;
  }
  auto dir = destDir.strip;
  if (dir.length == 0) {
    stderr.writeln("Cannot extract " ~ archive ~ ": no destination directory.");
    return r;
  }
  auto marker = buildPath(dir, stampFileName);
  auto stamp = archiveStamp(archive);
  if (!force && exists(dir) && stampMatches(marker, stamp)) {
    r.ok = true;
    r.dir = dir;
    r.reused = true;
    return r;
  }
  // 只在"我们自己解压出来的"目录上重解：没有标记的同名目录可能是用户数据
  if (exists(dir) && !exists(marker)) {
    stderr.writeln("Refusing to overwrite " ~ dir
        ~ ": it exists but is not a jstart extraction (missing " ~ baseName(marker) ~ ").");
    stderr.writeln("Remove it, or extract the archive yourself and declare [app] exec.");
    return r;
  }
  if (verbose) {
    writeln("Extracting " ~ archive ~ " -> " ~ dir);
  }
  // 解压到独立临时目录再整体改名：并发启动同一工件时不会互相看到半个目录
  auto tmp = makeTempDir(dirName(dir), baseName(dir));
  if (tmp.length == 0) {
    stderr.writeln("Cannot create a temporary extraction directory under "
        ~ dirName(dir));
    return r;
  }
  if (!runTar(archive, tmp)) {
    stderr.writeln("Cannot extract " ~ archive ~ " (tar failed)");
    rmTree(tmp);
    return r;
  }
  try {
    write(buildPath(tmp, stampFileName), stamp);
  } catch (Exception e) {
    // 标记写不了只是下次重解，不算失败
  }
  // 旧目录挪到一边（改名而不是原地删除：正在运行的实例仍持有旧 inode），
  // 再把新目录改名就位。落后的一方看到对方的目录就直接复用。
  // 并发下别人可能已把同一归档解压好：内容一致，直接复用，绝不挪走它
  // （运行中的实例仍在使用那个目录）。
  if (!force && exists(dir) && stampMatches(marker, stamp)) {
    rmTree(tmp);
    r.ok = true;
    r.dir = dir;
    r.reused = true;
    return r;
  }
  auto trash = dir ~ ".old-" ~ to!string(currentPid());
  rmTree(trash);
  if (exists(dir)) {
    try {
      rename(dir, trash);
    } catch (Exception e) {
      // 并发下对方可能刚挪走：交给下面的复用判断
    }
  }
  auto placed = false;
  try {
    rename(tmp, dir);
    placed = true;
  } catch (Exception e) {
    placed = false;
  }
  if (!placed) {
    if (stampMatches(marker, stamp)) {
      rmTree(tmp);
      r.ok = true;
      r.dir = dir;
      r.reused = true;
      return r;
    }
    stderr.writeln("Cannot move " ~ tmp ~ " to " ~ dir);
    rmTree(tmp);
    return r;
  }
  rmTree(trash);
  r.ok = true;
  r.dir = dir;
  return r;
}

/// Whether the marker file exists and records exactly this stamp.
private bool stampMatches(string marker, string stamp) {
  if (!exists(marker)) {
    return false;
  }
  try {
    return readText(marker).strip == stamp;
  } catch (Exception e) {
    return false;
  }
}

/// isFile without throwing when the path disappears concurrently.
private bool isFileOrGone(string path) {
  try {
    return exists(path) && isFile(path);
  } catch (Exception e) {
    return false;
  }
}

/**
 * Create a fresh private temporary directory under `parent`, named
 * `.<stem>.tmp-<pid>-<n>`. The name includes the pid because one process may
 * extract concurrently from several threads (several `run` instances started
 * by the same supervisor), and mkdir(2) is used so that two racers cannot both
 * believe they created the same directory. Returns "" on failure.
 */
private string makeTempDir(string parent, string stem) {
  try {
    if (!exists(parent)) {
      mkdirRecurse(parent);
    }
  } catch (Exception e) {
    return "";
  }
  version (Posix) {
    import core.sys.posix.sys.stat : mkdir;
    import std.conv : octal;
    import std.string : toStringz;

    foreach (attempt; 0 .. 100) {
      auto candidate = buildPath(parent,
          "." ~ stem ~ ".tmp-" ~ to!string(currentPid()) ~ "-" ~ to!string(attempt));
      if (mkdir(candidate.toStringz, octal!700) == 0) {
        return candidate;
      }
    }
    return "";
  } else {
    foreach (attempt; 0 .. 100) {
      auto candidate = buildPath(parent,
          "." ~ stem ~ ".tmp-" ~ to!string(currentPid()) ~ "-" ~ to!string(attempt));
      if (exists(candidate)) {
        continue;
      }
      try {
        mkdirRecurse(candidate);
        return candidate;
      } catch (Exception e) {
      }
    }
    return "";
  }
}

/**
 * Locate the executable inside an extracted distribution.
 *
 * Resolution order: an explicit `hint` (launch spec `[app] exec`, relative to
 * the extraction root) wins; otherwise a single top-level directory is
 * descended into, then `<root>/bin/<artifactId>`, then the only executable
 * under `bin/`, then the only executable in the tree (depth <= 3), then the
 * executable matching the artifact id.
 *
 * Returns "" when nothing was found or the choice is ambiguous; `candidates`
 * then lists the executables seen, so callers can print a useful hint.
 */
string findExecutable(string rootDir, string hint, string artifactId,
    out string[] candidates) {
  candidates = null;
  if (rootDir.length == 0 || !exists(rootDir) || !isDir(rootDir)) {
    return "";
  }
  auto root = rootDir;
  if (hint.length) {
    auto explicit = buildPath(root, hint.replace("\\", "/"));
    if (isFileOrGone(explicit)) {
      return ensureExecutable(explicit);
    }
    return "";
  }

  // <name>/bin/<executable> 布局：顶层只有一个目录时下沉一层
  auto topDirs = shallowDirs(root);
  auto topFiles = shallowFiles(root);
  if (topDirs.length == 1 && topFiles.length == 0) {
    root = topDirs[0];
  }

  if (artifactId.length) {
    auto named = buildPath(root, "bin", artifactId);
    if (isFileOrGone(named)) {
      return ensureExecutable(named);
    }
  }
  auto binExes = executableFiles(buildPath(root, "bin"), 1);
  if (binExes.length == 1) {
    return ensureExecutable(binExes[0]);
  }
  auto treeExes = executableFiles(root, 3);
  candidates = binExes.length ? binExes : treeExes;
  if (treeExes.length == 1) {
    return ensureExecutable(treeExes[0]);
  }
  if (artifactId.length) {
    foreach (f; binExes ~ treeExes) {
      if (baseName(f) == artifactId) {
        return ensureExecutable(f);
      }
    }
  }
  // 打包工具丢了执行位：bin/ 下只有一个常规文件时也认（补执行位后执行）
  auto binFiles = regularFiles(buildPath(root, "bin"), 1);
  if (binFiles.length == 1) {
    return ensureExecutable(binFiles[0]);
  }
  if (candidates.length == 0) {
    candidates = binFiles.length ? binFiles : regularFiles(root, 2);
  }
  return "";
}

/// Whether the host `tar` command is available.
bool tarAvailable() {
  try {
    auto input = File("/dev/null", "rb");
    auto output = File("/dev/null", "wb");
    scope (exit) {
      input.close();
      output.close();
    }
    return wait(spawnProcess(["tar", "--version"], input, output, stderr)) == 0;
  } catch (Exception e) {
    return false;
  }
}

/// Run `tar -xzf <archive> -C <dir>`; false on failure.
private bool runTar(string archive, string dir) {
  try {
    auto input = File("/dev/null", "rb");
    auto output = File("/dev/null", "wb");
    scope (exit) {
      input.close();
      output.close();
    }
    return wait(spawnProcess(["tar", "-xzf", archive, "-C", dir], input, output, stderr)) == 0;
  } catch (Exception e) {
    stderr.writeln("Cannot run tar: " ~ e.msg);
    return false;
  }
}

/// Archive stamp used to decide whether a cached extraction is still valid.
private string archiveStamp(string archive) {
  import std.datetime : SysTime;

  SysTime accessed;
  SysTime modified;
  getTimes(archive, accessed, modified);
  return to!string(getSize(archive)) ~ "-" ~ to!string(modified.toUnixTime);
}

/// Give the chosen executable the exec bit (packaging tools sometimes drop it).
private string ensureExecutable(string path) {
  version (Posix) {
    import core.sys.posix.sys.stat : chmod;
    import std.conv : octal;
    import std.string : toStringz;

    chmod(path.toStringz, octal!755);
  }
  return path;
}

private bool isExecutable(string path) {
  version (Posix) {
    import core.sys.posix.sys.stat : S_IXUSR, stat, stat_t;
    import std.string : toStringz;

    stat_t st;
    if (stat(path.toStringz, &st) != 0) {
      return false;
    }
    return (st.st_mode & S_IXUSR) != 0;
  } else {
    return true;
  }
}

private string[] shallowDirs(string dir) {
  string[] result;
  if (!exists(dir)) {
    return result;
  }
  foreach (e; dirEntries(dir, SpanMode.shallow)) {
    // 并发启动/重解时条目可能消失：探测不能因此崩溃
    try {
      if (e.isDir && !e.name.baseName.startsWith(".")) {
        result ~= e.name;
      }
    } catch (Exception e2) {
    }
  }
  sort(result);
  return result;
}

private string[] shallowFiles(string dir) {
  string[] result;
  if (!exists(dir)) {
    return result;
  }
  foreach (e; dirEntries(dir, SpanMode.shallow)) {
    try {
      if (e.isFile && !e.name.baseName.startsWith(".")) {
        result ~= e.name;
      }
    } catch (Exception e2) {
    }
  }
  sort(result);
  return result;
}

/// Regular files under dir, up to maxDepth levels below it.
private string[] regularFiles(string dir, int maxDepth) {
  string[] result;
  if (!exists(dir) || !isDir(dir)) {
    return result;
  }
  foreach (e; dirEntries(dir, SpanMode.depth)) {
    try {
      if (!e.isFile || e.name.baseName.startsWith(".") || depthOf(dir, e.name) > maxDepth) {
        continue;
      }
      result ~= e.name;
    } catch (Exception e2) {
    }
  }
  sort(result);
  return result;
}

/// Executable files under dir, up to maxDepth levels below it.
private string[] executableFiles(string dir, int maxDepth) {
  string[] result;
  foreach (f; regularFiles(dir, maxDepth)) {
    if (isExecutable(f)) {
      result ~= f;
    }
  }
  return result;
}

/// Depth of path below root (root itself is 0).
private int depthOf(string root, string path) {
  auto rel = path[root.length .. $];
  auto depth = 0;
  foreach (c; rel) {
    if (c == '/' || c == '\\') {
      depth++;
    }
  }
  return depth;
}

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

unittest {
  assert(isTarGzPackaging("tar.gz") && isTarGzPackaging("tgz"));
  assert(!isTarGzPackaging("jar") && !isTarGzPackaging("tar"));

  assert(targetGav("org.example:demo:tar.gz:linux-amd64:1.0")
      == "org.example:demo:tar.gz:linux-amd64:1.0");
  assert(targetGav("gav://org.example:demo:1.0") == "org.example:demo:1.0");
  assert(targetGav("/tmp/demo.tar.gz") == "");
  assert(targetGav("https://host/demo.tar.gz") == "");

  assert(isNativeTarget("org.example:demo:tar.gz:linux-amd64:1.0"));
  assert(isNativeTarget("gav://org.example:demo:tgz:x:1.0"));
  assert(isNativeTarget("/tmp/demo-1.0-linux-amd64.tar.gz"));
  assert(isNativeTarget("https://host/demo.tgz"));
  assert(!isNativeTarget("org.example:demo:1.0"));
  assert(!isNativeTarget("/tmp/demo.war"));
}
