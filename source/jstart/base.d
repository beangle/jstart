/**
 * The base directory of a component: where `run` keeps a component's run-time
 * state.
 *
 * A base is the **component directory below a base root**: the root defaults
 * to /var/tmp/jstart and `--base=<dir>` replaces it (it is not appended to
 * /var/tmp/jstart), so `--base=/srv/jstart` keeps app.war's state in
 * /srv/jstart/app.war-<指纹>/. Without `[app] instance` the component key
 * always ends with a short digest of the target, so several components can
 * share one root; `[app] instance = <name>` names the directory verbatim
 * instead (uniqueness under the root is then the user's responsibility):
 *
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
 * `run` replaces itself with the application (exec), so the jstart process
 * *becomes* the application process. Supervising a running instance -- keeping
 * its pid and stopping it -- is left to the caller (an upper-level launcher or
 * service manager).
 */
module jstart.base;

import std.file : exists, mkdirRecurse;
import std.path : absolutePath, baseName, buildPath;
import std.string : strip;
import std.stdio : stderr;

import jstart.archive : expandLocalPath;

/// Default base root: every component base lives below it.
enum defaultBaseRoot = "/var/tmp/jstart";

/// Directory inside a base holding the extracted native distribution.
enum nativeDirName = "app";

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
 * part of the key: the base depends only on the target.
 */
string componentKey(string target) {
  import std.digest : toHexString;
  import std.digest.sha : SHA1;

  auto text = target.strip;
  if (exists(text)) {
    // 本地路径做绝对化，./app.war 与 /abs/app.war 视为同一组件
    text = absolutePath(text);
  }
  SHA1 sha;
  sha.put(cast(const(ubyte)[]) text);
  auto hex = toHexString(sha.finish());

  auto stem = baseName(text);
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
 * Whether `name` is a single safe path segment usable as an explicit
 * `[app] instance`: non-empty, only [A-Za-z0-9._-], and neither `.` nor
 * `..`. Anything else (separators, spaces, NUL, traversal) is rejected so
 * that `run` and any later tool resolve the same directory.
 */
bool isSafeInstanceName(string name) {
  auto s = name.strip;
  if (s.length == 0 || s == "." || s == "..") {
    return false;
  }
  foreach (c; s) {
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
        || c == '.' || c == '-' || c == '_') {
      continue;
    }
    return false;
  }
  return true;
}

/**
 * The component directory below a base root: <root>/<组件键>, created 0700 and
 * verified to be owned by this user, so the instance state stays private even
 * when the root is shared (e.g. the default /var/tmp/jstart or a directory
 * several components use). "" when the root is empty or cannot be prepared.
 */
string componentBase(string root, string target) {
  if (root.strip.length == 0) {
    return "";
  }
  return privateDir(buildPath(root, componentKey(target)));
}

/**
 * Base of a component under the default root; "" when it cannot be prepared.
 */
string defaultBase(string target) {
  return componentBase(baseRootDir(), target);
}

/**
 * Base directory of a run. `explicit` (--base / [app] base) names the
 * **root** and thereby replaces the default /var/tmp/jstart. An explicit
 * `instance` ([app] instance) names the component directory verbatim
 * (<root>/<instance>) instead of the target-derived <组件键>; it must be a
 * safe path segment (see isSafeInstanceName). "" when the root or instance
 * cannot be prepared.
 */
string resolveBase(string target, string explicit = "", string instance = "") {
  auto root = baseRootDir(explicit);
  if (root.length == 0) {
    return "";
  }
  auto name = instance.strip;
  if (name.length == 0) {
    return componentBase(root, target);
  }
  if (!isSafeInstanceName(name)) {
    return "";
  }
  return privateDir(buildPath(root, name));
}
