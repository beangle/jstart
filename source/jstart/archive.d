/**
 * Dependency archive models and parsers.
 *
 * A jar/war prepared by the beangle maven plugin contains a file
 * /META-INF/beangle/dependencies whose lines describe external archives:
 *
 *   - group:artifact:version           plain gav, packaging is jar
 *   - group:artifact:packaging:version 4-part gav
 *   - group:artifact:packaging:classifier:version 5-part gav
 *   - gav://<gav>                      explicit gav url
 *   - http(s)://host/...               remote file, cached under local repo
 *   - /path/to/local.jar (file://, ~, ${VAR}) local file
 */
module jstart.archive;

import std.algorithm : canFind;
import std.array : split;
import std.process : environment;
import std.string : indexOf, replace, startsWith, strip;

/** Maven packaging types recognized in the third part of a 4-part gav. */
immutable string[] mavenPackagings = [
  "jar", "war", "pom", "zip", "ear", "rar", "ejb", "ejb3", "tar", "tar.gz"
];

/** Base class of every archive described in a dependencies file. */
abstract class Archive {
  /** The original line describing this archive. */
  string raw;

  this(string raw) {
    this.raw = raw;
  }

  override string toString() const {
    return raw;
  }
}

/** A maven repository artifact. */
final class Artifact : Archive {
  string groupId;
  string artifactId;
  string ver;
  /** Empty when the artifact has no classifier. */
  string classifier;
  string packaging;

  this(string raw, string groupId, string artifactId, string ver,
      string classifier, string packaging) {
    super(raw);
    this.groupId = groupId;
    this.artifactId = artifactId;
    this.ver = ver;
    this.classifier = classifier;
    this.packaging = packaging;
  }

  bool isSnapshot() const {
    return ver.canFind("SNAPSHOT");
  }

  /// A copy with another packaging, e.g. jar -> war.
  Artifact withPackaging(string p) const {
    return new Artifact(raw, groupId, artifactId, ver, classifier, p);
  }

  /// The companion .sha1 artifact stored beside this artifact.
  Artifact sha1() const {
    return new Artifact(raw, groupId, artifactId, ver, classifier, packaging ~ ".sha1");
  }

  /// Maven2 repository relative path, e.g. /org/slf4j/slf4j-api/2.0.17/slf4j-api-2.0.17.jar
  string layoutPath() const {
    auto file = artifactId ~ "-" ~ ver;
    if (classifier.length) {
      file ~= "-" ~ classifier;
    }
    return "/" ~ groupId.replace(".", "/") ~ "/" ~ artifactId ~ "/" ~ ver ~ "/"
      ~ file ~ "." ~ packaging;
  }
}

/** A local file dependency. */
final class LocalFile : Archive {
  string file;

  this(string raw, string file) {
    super(raw);
    this.file = file;
  }
}

/** A remote file dependency, cached under the local repository by host path. */
final class RemoteFile : Archive {
  string url;

  this(string raw, string url) {
    super(raw);
    this.url = url;
  }
}

/**
 * Parse a gav string into an Artifact.
 *
 * Supported forms:
 *   group:artifact:version
 *   group:artifact:packaging:version          (or group:artifact:classifier:version)
 *   group:artifact:packaging:classifier:version
 */
Artifact parseGav(string raw, string gav) {
  auto parts = gav.split(":");
  if (parts.length == 3) {
    return new Artifact(raw, parts[0], parts[1], parts[2], "", "jar");
  } else if (parts.length == 4) {
    auto cOp = parts[2];
    if (mavenPackagings.canFind(cOp)) {
      return new Artifact(raw, parts[0], parts[1], parts[3], "", cOp);
    }
    return new Artifact(raw, parts[0], parts[1], parts[3], cOp, "jar");
  } else if (parts.length == 5) {
    return new Artifact(raw, parts[0], parts[1], parts[4], parts[3], parts[2]);
  }
  throw new Exception("Cannot recognize artifact format " ~ gav);
}

/** Parse one line of a dependencies file; returns null for empty lines. */
Archive parseArchive(string line) {
  auto s = line.strip;
  if (s.length == 0) {
    return null;
  }
  if (s.startsWith("http://") || s.startsWith("https://")) {
    return new RemoteFile(s, s);
  }
  if (s.startsWith("gav://")) {
    return parseGav(s, s["gav://".length .. $]);
  }
  if (!s.canFind("/") && !s.canFind("\\")) {
    return parseGav(s, s);
  }
  string f = s;
  if (f.startsWith("file://")) {
    f = f["file://".length .. $];
  }
  return new LocalFile(s, expandLocalPath(f));
}

/**
 * Expand ~ and ${VAR} placeholders in a local path.
 * An unknown ${VAR} is left as its plain variable name, mirroring the
 * original java implementation.
 */
string expandLocalPath(string path) {
  string f = path;
  if (f.startsWith("~")) {
    auto home = environment.get("HOME");
    if (home.length == 0) {
      home = "~";
    }
    f = home ~ f[1 .. $];
  }
  while (true) {
    auto start = f.indexOf("${");
    if (start < 0) {
      break;
    }
    auto end = f.indexOf("}", start + 2);
    if (end < 0) {
      break;
    }
    auto name = f[start + 2 .. end];
    auto value = environment.get(name);
    if (value.length == 0) {
      value = name;
    }
    f = f[0 .. start] ~ value ~ f[end + 1 .. $];
  }
  return f;
}
