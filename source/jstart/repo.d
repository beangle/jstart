/**
 * Local and remote maven repositories, plus sha1 helpers.
 */
module jstart.repo;

import std.algorithm : endsWith;
import std.array : split;
import std.conv : to;
import std.digest : digest, toHexString;
import std.digest.sha : SHA1;
import std.file : dirEntries, exists, isDir, mkdirRecurse, read, readText, SpanMode;
import std.path : baseName, dirName;
import std.process : environment;
import std.string : indexOf, lastIndexOf, startsWith, strip, toLower;

import jstart.archive : Artifact, expandLocalPath;

/** Local maven repository, ~/.m2/repository by default. */
final class LocalRepo {
  /// Repository base directory, no trailing slash.
  string base;
  /// Timestamped snapshot lookup base, ~/.m2/snapshots by default.
  string snapshotBase;

  this(string base = "", string snapshotBaseDir = "") {
    auto given = base.strip;
    string b = given.length ? expandLocalPath(given) : defaultLocalBase();
    while (b.length > 1 && b[$ - 1] == '/') {
      b = b[0 .. $ - 1];
    }
    this.base = b;
    auto givenSnapshot = snapshotBaseDir.strip;
    if (givenSnapshot.length) {
      auto snap = expandLocalPath(givenSnapshot);
      while (snap.length > 1 && snap[$ - 1] == '/') {
        snap = snap[0 .. $ - 1];
      }
      this.snapshotBase = snap;
    } else {
      // 与 beangle/boot 一致：显式给出 base 时快照也放该 base；默认才是
      // ~/.m2/snapshots。
      this.snapshotBase = given.length ? b : defaultSnapshotBase();
    }
    if (!exists(this.base)) {
      mkdirRecurse(this.base);
    }
  }

  /// Absolute path of an artifact inside this repository.
  string filePath(Artifact a) const {
    return base ~ a.layoutPath;
  }

  /**
   * Latest local timestamped snapshot file for a snapshot artifact, e.g.
   * <snapshotBase>/g/a/1.0-SNAPSHOT/a-1.0-20260101.010101-2.jar, or ""
   * when none exists. Timestamp format: yyyyMMdd.HHmmss-build, the newest
   * (timestamp, build) pair wins, mirroring beangle/boot LocalSnapshot.
   */
  string snapshotPathOf(Artifact a) const {
    if (!a.isSnapshot) {
      return "";
    }
    auto ver = a.ver;
    if (ver.endsWith("-SNAPSHOT")) {
      ver = ver[0 .. $ - "-SNAPSHOT".length];
    }
    auto dir = dirName(snapshotBase ~ a.layoutPath);
    if (!exists(dir) || !isDir(dir)) {
      return "";
    }
    auto prefix = a.artifactId ~ "-" ~ ver ~ "-";
    auto ext = "." ~ a.packaging;
    string bestName;
    string bestTs;
    auto bestBuild = -1;
    foreach (e; dirEntries(dir, SpanMode.shallow)) {
      auto name = baseName(e.name);
      if (!name.startsWith(prefix) || !name.endsWith(ext)) {
        continue;
      }
      // <时间戳>-<构建号>[-<classifier>]，classifier 自身可含 '-'
      auto mid = name[prefix.length .. $ - ext.length];
      if (mid.length < 16 || mid[8] != '.') {
        continue;
      }
      auto ts = mid[0 .. 15];
      if (!isTimestampVersion(ts) || mid[15] != '-') {
        continue;
      }
      auto rest = mid[16 .. $];
      auto dash = rest.indexOf("-");
      auto buildText = dash < 0 ? rest : rest[0 .. dash];
      auto classifier = dash < 0 ? "" : rest[dash + 1 .. $];
      if (classifier != a.classifier) {
        continue;
      }
      auto build = -1;
      try {
        build = to!int(buildText);
      } catch (Exception e) {
        continue;
      }
      if (ts > bestTs || (ts == bestTs && build > bestBuild)) {
        bestTs = ts;
        bestBuild = build;
        bestName = name;
      }
    }
    return bestName.length ? dir ~ "/" ~ bestName : "";
  }

  /** yyyyMMdd.HHmmss, e.g. 20260101.010101. */
  private static bool isTimestampVersion(string ts) {
    if (ts.length != 15 || ts[8] != '.') {
      return false;
    }
    foreach (i, c; ts) {
      if (i != 8 && (c < '0' || c > '9')) {
        return false;
      }
    }
    return true;
  }
}

/// Default local repository location.
string defaultLocalBase() {
  auto home = environment.get("HOME");
  if (home.length == 0) {
    home = ".";
  }
  return home ~ "/.m2/repository";
}

/// Default timestamped snapshot repository location.
string defaultSnapshotBase() {
  auto home = environment.get("HOME");
  if (home.length == 0) {
    home = ".";
  }
  return home ~ "/.m2/snapshots";
}

/** sha1 hex digest of a file. */
string sha1OfFile(string path) {
  auto dg = digest!SHA1(cast(ubyte[]) read(path));
  return toHexString(dg).toLower;
}

/** Parse a .sha1 file, returns the first whitespace separated token. */
string parseSha1Text(string text) {
  auto parts = text.strip.split;
  if (parts.length == 0) {
    return "";
  }
  auto token = parts[0];
  if (token.length >= 40) {
    token = token[0 .. 40];
  }
  return token.toLower;
}

/**
 * Verify an artifact against its local .sha1 companion file.
 * Returns true when matched, false on mismatch.
 */
bool verifySha1(LocalRepo local, Artifact a) {
  auto sha1File = local.filePath(a.sha1);
  if (!exists(sha1File)) {
    return true; // nothing to verify against
  }
  auto expected = parseSha1Text(readText(sha1File));
  auto actual = sha1OfFile(local.filePath(a));
  return expected.length == 40 && expected == actual;
}

/** A remote maven repository. */
struct RemoteRepo {
  /// Identifier, defaults to the repository url.
  string id;
  /// Base url, no trailing slash.
  string base;
}

/** Default remote repositories: aliyun, huaweicloud and maven central. */
RemoteRepo[] defaultRemotes() {
  return [
    RemoteRepo("aliyun", "https://maven.aliyun.com/repository/public"),
    RemoteRepo("huaweicloud", "https://repo.huaweicloud.com/repository/maven"),
    RemoteRepo("central", "https://repo1.maven.org/maven2")
  ];
}

/**
 * Build the remote repository list from a comma separated spec.
 * Maven central is appended when absent, mirroring the original behavior.
 */
RemoteRepo[] buildRemotes(string spec = "") {
  if (spec.strip.length == 0) {
    return defaultRemotes();
  }
  RemoteRepo[] remotes;
  foreach (b; spec.split(",")) {
    auto base = b.strip;
    if (base.length == 0) {
      continue;
    }
    if (!base.startsWith("http://") && !base.startsWith("https://")) {
      base = "http://" ~ base;
    }
    while (base.length > 1 && base[$ - 1] == '/') {
      base = base[0 .. $ - 1];
    }
    remotes ~= RemoteRepo(base, base);
  }
  auto central = defaultRemotes()[2];
  foreach (r; remotes) {
    if (r.base == central.base) {
      return remotes;
    }
  }
  remotes ~= central;
  return remotes;
}
