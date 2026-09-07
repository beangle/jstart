/**
 * Local and remote maven repositories, plus sha1 helpers.
 */
module jstart.repo;

import std.array : split;
import std.digest : digest, toHexString;
import std.digest.sha : SHA1;
import std.file : exists, mkdirRecurse, read, readText;
import std.process : environment;
import std.string : startsWith, strip, toLower;

import jstart.archive : Artifact, expandLocalPath;

/** Local maven repository, ~/.m2/repository by default. */
final class LocalRepo {
  /// Repository base directory, no trailing slash.
  string base;

  this(string base = "") {
    string b = base.length ? expandLocalPath(base.strip) : defaultLocalBase();
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
