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
import std.path : baseName;
import std.process : environment;
import std.string : indexOf, lastIndexOf, startsWith, strip, toLower;

import jstart.archive : Artifact, expandLocalPath;

/**
 * Local maven repository, ~/.m2/repository by default.
 *
 * 只有一个仓库：正式版与 SNAPSHOT 都在 maven2 布局的版本目录下
 * （`<base>/g/a/<version>/`）。SNAPSHOT 的版本目录里通常放带时间戳的
 * 构建文件，另可有 `a-1.0-SNAPSHOT.jar` 这样的字面别名；两者共存，
 * 由 [[snapshotPathOf]] 取最新时间戳的那个。
 */
final class LocalRepo {
  /// Repository base directory, no trailing slash.
  string base;

  this(string base = "") {
    auto given = base.strip;
    string b = given.length ? expandLocalPath(given) : defaultLocalBase();
    while (b.length > 1 && b[$ - 1] == '/') {
      b = b[0 .. $ - 1];
    }
    this.base = b;
    if (!exists(this.base)) {
      mkdirRecurse(this.base);
    }
  }

  /// Absolute path of an artifact inside this repository.
  string filePath(Artifact a) const {
    return base ~ a.layoutPath;
  }

  /// 该构件的版本目录（绝对路径，不带尾斜杠）：正式版与 SNAPSHOT 同一布局。
  string snapshotDirOf(Artifact a) const {
    return base ~ a.dirPath;
  }

  /// 版本目录下某个具体文件（通常是 SNAPSHOT 时间戳文件）的绝对路径。
  string snapshotPathFor(Artifact a, string fileName) const {
    return snapshotDirOf(a) ~ "/" ~ fileName;
  }

  /**
   * Latest local timestamped snapshot file for a snapshot artifact, e.g.
   * <base>/g/a/1.0-SNAPSHOT/a-1.0-20260101.010101-2.jar, or "" when none
   * exists. Timestamp format: yyyyMMdd.HHmmss-build; the newest
   * (timestamp, build) pair wins, so a newer download always shadows the
   * previous build in the same version directory.
   */
  string snapshotPathOf(Artifact a) const {
    if (!a.isSnapshot) {
      return "";
    }
    auto ver = a.ver;
    if (ver.endsWith("-SNAPSHOT")) {
      ver = ver[0 .. $ - "-SNAPSHOT".length];
    }
    auto dir = snapshotDirOf(a);
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
  return verifySha1File(local.filePath(a), local.filePath(a.sha1));
}

/** 校验任意文件与其 `.sha1` 伴随文件；伴随文件缺失时视为通过（无从校验）。 */
bool verifySha1File(string file, string sha1File) {
  if (!exists(sha1File)) {
    return true; // nothing to verify against
  }
  auto expected = parseSha1Text(readText(sha1File));
  auto actual = sha1OfFile(file);
  return expected.length == 40 && expected == actual;
}

/** A remote maven repository. */
struct RemoteRepo {
  /// Identifier, defaults to the repository url.
  string id;
  /// Base url, no trailing slash.
  string base;
}

/**
 * Default remote repositories: aliyun, huaweicloud and maven central.
 *
 * 这是「内置镜像 + Central 兜底」策略的唯一出处：调用方（bas 等）只透传自己配置的
 * 仓库列表，不再各拼一份默认值；`buildRemotes` 在给定列表缺少 Central 时补到末尾。
 * 需要完全离线时用 `--offline`，不要依赖空 `--remote`。
 */
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
  auto remotes = parseRemotes(spec);
  auto central = defaultRemotes()[2];
  foreach (r; remotes) {
    if (r.base == central.base) {
      return remotes;
    }
  }
  remotes ~= central;
  return remotes;
}

/**
 * SNAPSHOT 解析专用的上游列表：**只用 spec 里显式给出的仓库**，不追加 Central、不给
 * 缺省镜像；spec 为空即空列表（只用本地仓库）。
 *
 * 开发版构件通常来自专用的快照/开发仓库，把它兜到公共镜像既没必要、也会造成
 * 「明明没配快照上游却从公网拉开发版」的意外；普通构件仍由 [[buildRemotes]] 提供默认
 * 镜像与 Central 兜底。两者可以不同（`jstart.resolver` 分别持有 remotes / snapshotRemotes）。
 */
RemoteRepo[] buildSnapshotRemotes(string spec = "") {
  return parseRemotes(spec);
}

/// 解析逗号分隔的仓库 spec：补 http://、去尾斜杠、丢弃空项；不附加任何默认值。
private RemoteRepo[] parseRemotes(string spec) {
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
  return remotes;
}
