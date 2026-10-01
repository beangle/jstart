/**
 * The base directory of a component: where `run`/`stop` keep a component's
 * run-time state.
 *
 * An instance is identified by **component + base**, never by the pass-through
 * arguments: one component runs at most one instance per base. A second copy
 * needs its own base -- `--base=<dir>` (a different root), `--instance=<name>`
 * (a named component directory) or launch spec `[app] base`.
 *
 * A base is the **component directory below a base root**: the root defaults
 * to /var/tmp/jstart and `--base=<dir>` replaces it (it is not appended to
 * /var/tmp/jstart), so `--base=/srv/jstart` keeps app.war's state in
 * /srv/jstart/app.war-<指纹>/. The component key always ends with a short
 * digest of the target, so several components can share one root:
 *
 *   <root>/<组件键>/app.pid          pid of the running instance (run/stop)
 *   <root>/<组件键>/app/             native tar.gz extraction (jstart.native)
 *   <root>/<组件键>/webapps/<ctx>/   war explosion (engine gets --base=<base>)
 *
 * /var/tmp is preferred over /tmp for the default root: it is usually a real
 * filesystem (not tmpfs) and not mounted noexec, and systemd-tmpfiles cleans
 * it far less aggressively (30d vs 10d by default). The default root is
 * created 01777 (sticky, like /tmp) so that every user may keep components
 * below it; the component directory itself is created 0700 and verified to be
 * owned by this user, so nobody else can plant (and execute from) or read
 * another user's instance state.
 *
 * `run` replaces itself with the application (exec), which means the jstart
 * process *becomes* the application process: writing getpid() just before
 * exec records the application's real pid. The file is written atomically
 * (temp file + rename) and carries the process start time, so `stop` can tell
 * a live application from a recycled pid. `stop` only needs the base, so it
 * works without resolving (or downloading) anything.
 */
module jstart.base;

import std.array : split;
import std.conv : to;
import std.file : dirEntries, exists, mkdirRecurse, readText, remove, rename, SpanMode, write;
import std.path : absolutePath, baseName, buildPath, dirName;
import std.string : indexOf, strip;
import std.stdio : stderr, writeln;

import jstart.archive : expandLocalPath;

/// Default base root: every component base lives below it.
enum defaultBaseRoot = "/var/tmp/jstart";

/// File name of the pid file inside a base.
enum pidFileName = "app.pid";

/// Directory inside a base holding the extracted native distribution.
enum nativeDirName = "app";

/// Contents of a pid file.
struct PidInfo {
  /// Process id (0 when unknown).
  long pid;
  /// Process start time from /proc/<pid>/stat ("" when unavailable); used to
  /// detect a recycled pid.
  string start;
  /// The command line target the application was started from.
  string target;
  /// The resolved application (jar/war path, native archive, ...).
  string app;
}

/**
 * Prepare and return the root that holds the component bases: `explicit`
 * (--base / [app] base; `~` expanded, relative paths resolved against the cwd)
 * when given, else `defaultBaseRoot`. A root may be shared by several users or
 * components, so it only has to exist and be a directory -- the per-instance
 * privacy is enforced on the component directory (see componentBase). The
 * default root is made world-writable + sticky (01777, like /tmp) when we own
 * it, so that every user can create components below it but cannot remove or
 * rename someone else's. Returns "" when the root cannot be used.
 */
string baseRootDir(string explicit = "") {
  version (Posix) {
    import core.sys.posix.sys.stat : S_IFDIR, S_IFMT, S_ISVTX, S_IWOTH, chmod, stat, stat_t;
    import core.sys.posix.unistd : getuid;
    import std.conv : octal;
    import std.string : toStringz;

    auto o = explicit.strip;
    auto dir = o.length ? absolutePath(expandLocalPath(o)) : defaultBaseRoot;
    try {
      if (!exists(dir)) {
        mkdirRecurse(dir);
      }
    } catch (Exception e) {
      stderr.writeln("Cannot prepare the base root " ~ dir ~ ": " ~ e.msg);
      return "";
    }
    stat_t st;
    if (stat(dir.toStringz, &st) != 0 || (st.st_mode & S_IFMT) != S_IFDIR) {
      stderr.writeln("Base root " ~ dir ~ " is not a directory.");
      return "";
    }
    if (!o.length && st.st_uid == getuid()
        && (st.st_mode & (S_ISVTX | S_IWOTH)) != (S_ISVTX | S_IWOTH)) {
      chmod(dir.toStringz, octal!1777);
    }
    return dir;
  } else {
    return "";
  }
}

/**
 * Create (when needed) and verify a private directory: it must exist, be a
 * real directory (not a symlink an attacker could have planted), be owned by
 * this user and carry no group/other write bit. The mode is then forced to
 * 0700. Returns the path, or "" on failure.
 */
private string privateDir(string dir) {
  version (Posix) {
    import core.sys.posix.sys.stat : S_IFDIR, S_IFMT, S_IWGRP, S_IWOTH, chmod, lstat, stat_t;
    import core.sys.posix.unistd : getuid;
    import std.conv : octal;
    import std.string : toStringz;

    auto uid = getuid();
    try {
      if (!exists(dir)) {
        mkdirRecurse(dir);
      }
    } catch (Exception e) {
      stderr.writeln("Cannot prepare " ~ dir ~ ": " ~ e.msg);
      return "";
    }
    stat_t st;
    // lstat: 拒绝符号链接（即便链接指向自己的目录），避免在共享根下被顶替
    if (lstat(dir.toStringz, &st) != 0 || (st.st_mode & S_IFMT) != S_IFDIR
        || st.st_uid != uid || (st.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
      stderr.writeln("Refusing to use " ~ dir
          ~ ": not a private directory owned by this user (pass --base=<your own dir>).");
      return "";
    }
    chmod(dir.toStringz, octal!700);
    return dir;
  } else {
    return "";
  }
}

/**
 * Key naming a component's base: a sanitized name part plus a short digest of
 * the target, so the same target always maps to the same base and different
 * targets never collide. The pass-through arguments are deliberately **not**
 * part of the key -- run/stop must agree without knowing them.
 */
string componentKey(string target, string name = "") {
  import std.digest : toHexString;
  import std.digest.sha : SHA1;

  auto text = target.strip;
  if (exists(text)) {
    // 本地路径做绝对化，./app.war 与 /abs/app.war 视为同一组件
    text = absolutePath(text);
  }
  SHA1 sha;
  sha.put(cast(const(ubyte)[]) (text ~ "\n" ~ name.strip));
  auto hex = toHexString(sha.finish());

  auto stem = name.strip.length ? name.strip : baseName(text);
  if (stem.length == 0) {
    stem = text;
  }
  string cleaned;
  foreach (c; stem) {
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
        || c == '.' || c == '-' || c == '_') {
      cleaned ~= c;
    } else {
      cleaned ~= '_';
    }
  }
  if (cleaned.length > 48) {
    cleaned = cleaned[0 .. 48];
  }
  return (cleaned ~ "-" ~ hex[0 .. 8]).idup;
}

/**
 * The component directory below a base root: <root>/<组件键>, created 0700 and
 * verified to be owned by this user, so the instance state stays private even
 * when the root is shared (e.g. the default /var/tmp/jstart or a directory
 * several components use). "" when the root is empty or cannot be prepared.
 */
string componentBase(string root, string target, string name = "") {
  if (root.strip.length == 0) {
    return "";
  }
  return privateDir(buildPath(root, componentKey(target, name)));
}

/**
 * Base of a component under the default root; "" when it cannot be prepared.
 */
string defaultBase(string target, string name = "") {
  return componentBase(baseRootDir(), target, name);
}

/**
 * Base directory of a run/stop. `explicit` (--base / [app] base) names the
 * **root** and thereby replaces the default /var/tmp/jstart; `name`
 * (--instance) names the component directory instead of the target's file
 * name. The result is always <root>/<组件键>. "" when it cannot be prepared.
 */
string resolveBase(string target, string explicit = "", string name = "") {
  return componentBase(baseRootDir(explicit), target, name);
}

/// Pid file of a base; "" when the base is unknown.
string pidFilePath(string base) {
  if (base.strip.length == 0) {
    return "";
  }
  return buildPath(base, pidFileName);
}

/// Whether the pid file names a process that is alive and not a zombie.
bool processAlive(long pid) {
  version (Posix) {
    import core.sys.posix.signal : kill;

    if (pid <= 0) {
      return false;
    }
    // Signal 0 only performs the permission/existence check.
    if (kill(cast(int) pid, 0) != 0) {
      return false;
    }
    return processState(pid) != "Z"; // 僵尸进程尚未被回收，不算在运行
  } else {
    return false;
  }
}

/// Single-letter process state from /proc/<pid>/stat ("" when unavailable).
private string processState(long pid) {
  return readProcStat(pid).state;
}

/**
 * Start time of a process (field 22 of /proc/<pid>/stat, clock ticks since
 * boot); "" when it cannot be read. Together with the pid this identifies a
 * process across pid reuse.
 */
string processStartTime(long pid) {
  return readProcStat(pid).start;
}

/// The two /proc/<pid>/stat fields a supervisor needs: state and start time.
private struct ProcStat {
  string state;
  string start;
}

private ptrdiff_t indexOfFromEnd(string s, char c) {
  for (auto i = s.length; i > 0; i--) {
    if (s[i - 1] == c) {
      return cast(ptrdiff_t) (i - 1);
    }
  }
  return -1;
}

/**
 * Parse /proc/<pid>/stat: `<pid> (<comm>) <state> ...`. `comm` may contain
 * spaces and parentheses, so fields are counted after the *last* ')'.
 * Returns empty strings when the file cannot be read (non-Linux, gone).
 */
private ProcStat readProcStat(long pid) {
  ProcStat r;
  version (linux) {
    string stat;
    try {
      stat = readText("/proc/" ~ to!string(pid) ~ "/stat");
    } catch (Exception e) {
      return r;
    }
    auto close = indexOfFromEnd(stat, ')');
    if (close < 0) {
      return r;
    }
    auto fields = stat[close + 1 .. $].split;
    // fields[0] is the state (field 3 overall); start time is field 22 => [19].
    if (fields.length > 0) {
      r.state = fields[0].strip;
    }
    if (fields.length > 19) {
      r.start = fields[19].strip;
    }
  }
  return r;
}

/// Read a pid file; false when it is missing or malformed.
bool readPidFile(string path, out PidInfo info) {
  info = PidInfo.init;
  string text;
  try {
    text = readText(path);
  } catch (Exception e) {
    return false;
  }
  foreach (line; text.split("\n")) {
    auto l = line.strip;
    auto eq = l.indexOf("=");
    if (eq <= 0) {
      continue;
    }
    auto key = l[0 .. eq].strip;
    auto value = l[eq + 1 .. $].strip;
    switch (key) {
      case "pid":
        try {
          info.pid = to!long(value);
        } catch (Exception e) {
          info.pid = 0;
        }
        break;
      case "start":
        info.start = value;
        break;
      case "target":
        info.target = value;
        break;
      case "app":
        info.app = value;
        break;
      default:
        break;
    }
  }
  return info.pid > 0;
}

/**
 * Remove a pid file; false when it did not exist. A file named app.pid sits in
 * the component directory jstart created, so the now-empty directory tree
 * below it is dropped too (a war leaves the exploded tree behind when the
 * engine removes docBase, and an extraction tree may be empty after a failed
 * unpack), keeping a clean stop from piling up empty directories. The base
 * root itself is never touched: only the component directory and below.
 */
bool removePidFile(string path) {
  if (!exists(path)) {
    return false;
  }
  try {
    remove(path);
  } catch (Exception e) {
    return false;
  }
  if (baseName(path) == pidFileName) {
    pruneEmptyTree(dirName(path));
  }
  return true;
}

/// Remove empty directories below (and including) dir, deepest first.
private void pruneEmptyTree(string dir) {
  import std.file : rmdir;

  try {
    foreach (e; dirEntries(dir, SpanMode.shallow)) {
      try {
        if (e.isDir) {
          pruneEmptyTree(e.name);
        }
      } catch (Exception e2) {
        // 条目消失（并发清理）时忽略
      }
    }
  } catch (Exception e) {
  }
  try {
    rmdir(dir); // 非空（应用自留文件）时留下
  } catch (Exception e) {
  }
}

/// Pid of the current process (0 on non-POSIX systems).
long currentPid() {
  version (Posix) {
    import core.sys.posix.unistd : getpid;

    return getpid();
  } else {
    return 0;
  }
}

/// Write a pid file for this process (called right before exec).
bool writePidFile(string path, string target, string app, out string err) {
  version (Posix) {
    import core.sys.posix.unistd : getpid;

    auto pid = getpid();
    return writePidFileFor(path, pid, processStartTime(pid), target, app, err);
  } else {
    err = "pid files are only supported on POSIX systems";
    return false;
  }
}

/// Write a pid file for an explicit pid/start (used by tests and `run`).
bool writePidFileFor(string path, long pid, string start, string target, string app,
    out string err) {
  auto dir = dirName(path);
  try {
    if (dir.length) {
      mkdirRecurse(dir);
    }
    auto body = "pid=" ~ to!string(pid) ~ "\n";
    if (start.length) {
      body ~= "start=" ~ start ~ "\n";
    }
    body ~= "target=" ~ target ~ "\n";
    if (app.length) {
      body ~= "app=" ~ app ~ "\n";
    }
    auto tmp = path ~ ".tmp";
    write(tmp, body);
    rename(tmp, path); // 同目录 rename：读者要么看到旧内容，要么看到新内容
    return true;
  } catch (Exception e) {
    err = e.msg;
    return false;
  }
}

/// Exit code of a successful `stop`.
enum stopOk = 0;
/// Exit code of `stop` when nothing was running (stale/missing pid file).
enum stopNotRunning = 3;

/**
 * Stop the application named by a pid file: SIGTERM, wait up to `timeoutSec`
 * for it to exit, then (with `force`) SIGKILL. A stale pid file (dead pid, or
 * a recycled pid whose start time differs) is removed and reported as
 * "not running".
 */
int stopApplication(string path, int timeoutSec, bool force, bool verbose = true) {
  version (Posix) {
    import core.sys.posix.signal : SIGKILL, SIGTERM, kill;
    import core.sys.posix.unistd : getpid;
    import core.thread : Thread;
    import core.time : msecs;

    if (!exists(path)) {
      stderr.writeln("No pid file " ~ path ~ ": nothing to stop.");
      return stopNotRunning;
    }
    PidInfo info;
    if (!readPidFile(path, info)) {
      stderr.writeln("Malformed pid file " ~ path ~ " (no pid= line).");
      return stopNotRunning;
    }
    if (info.pid == getpid()) {
      stderr.writeln("Pid file " ~ path ~ " points at this process; refusing to stop.");
      return 1;
    }
    if (!processAlive(info.pid)) {
      stderr.writeln("Not running (stale pid file " ~ path ~ ", pid " ~ to!string(info.pid)
          ~ " is gone).");
      removePidFile(path);
      return stopNotRunning;
    }
    auto start = processStartTime(info.pid);
    if (info.start.length && start.length && info.start != start) {
      stderr.writeln("Not running (pid " ~ to!string(info.pid)
          ~ " was recycled by another process; stale pid file " ~ path ~ ").");
      removePidFile(path);
      return stopNotRunning;
    }
    if (verbose) {
      writeln("Stopping pid " ~ to!string(info.pid)
          ~ (info.app.length ? " (" ~ info.app ~ ")" : "") ~ " ...");
    }
    if (kill(cast(int) info.pid, SIGTERM) != 0) {
      stderr.writeln("Cannot signal pid " ~ to!string(info.pid) ~ " with SIGTERM.");
      return 1;
    }
    auto waited = 0;
    while (waited < timeoutSec * 10 && processAlive(info.pid)) {
      Thread.sleep(100.msecs);
      waited++;
    }
    if (!processAlive(info.pid)) {
      removePidFile(path);
      if (verbose) {
        writeln("Stopped pid " ~ to!string(info.pid) ~ ".");
      }
      return stopOk;
    }
    if (!force) {
      stderr.writeln("Pid " ~ to!string(info.pid) ~ " did not stop within "
          ~ to!string(timeoutSec) ~ "s; use --force to SIGKILL (or --timeout=<sec>).");
      return 1;
    }
    if (verbose) {
      writeln("Pid " ~ to!string(info.pid) ~ " ignored SIGTERM; sending SIGKILL.");
    }
    if (kill(cast(int) info.pid, SIGKILL) != 0) {
      stderr.writeln("Cannot signal pid " ~ to!string(info.pid) ~ " with SIGKILL.");
      return 1;
    }
    waited = 0;
    while (waited < 50 && processAlive(info.pid)) {
      Thread.sleep(100.msecs);
      waited++;
    }
    if (processAlive(info.pid)) {
      stderr.writeln("Pid " ~ to!string(info.pid) ~ " is still running after SIGKILL.");
      return 1;
    }
    removePidFile(path);
    if (verbose) {
      writeln("Killed pid " ~ to!string(info.pid) ~ ".");
    }
    return stopOk;
  } else {
    stderr.writeln("stop is only supported on POSIX systems.");
    return 1;
  }
}
