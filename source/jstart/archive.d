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
import std.string : endsWith, indexOf, replace, startsWith, strip;

/** Maven packaging types recognized in the third part of a 4-part gav. */
immutable string[] mavenPackagings = [
  "jar", "war", "pom", "zip", "ear", "rar", "ejb", "ejb3", "tar", "tar.gz", "tgz"
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

  /// 去掉 `-SNAPSHOT` 后的版本基（正式版原样返回），即快照时间戳文件名里的版本部分。
  string baseVersion() const {
    return ver.endsWith("-SNAPSHOT") ? ver[0 .. $ - "-SNAPSHOT".length] : ver;
  }

  /// A copy with another packaging, e.g. jar -> war.
  Artifact withPackaging(string p) const {
    return new Artifact(raw, groupId, artifactId, ver, classifier, p);
  }

  /// A copy with another version, e.g. the local baseline of a delta.
  Artifact withVersion(string v) const {
    return new Artifact(raw, groupId, artifactId, v, classifier, packaging);
  }

  /// File name inside the version directory, e.g. demo-1.0-linux-amd64.tar.gz.
  string fileName() const {
    auto file = artifactId ~ "-" ~ ver;
    if (classifier.length) {
      file ~= "-" ~ classifier;
    }
    return file ~ "." ~ packaging;
  }

  /// The companion .sha1 artifact stored beside this artifact.
  Artifact sha1() const {
    return new Artifact(raw, groupId, artifactId, ver, classifier, packaging ~ ".sha1");
  }

  /// Maven2 repository relative path, e.g. /org/slf4j/slf4j-api/2.0.17/slf4j-api-2.0.17.jar
  string layoutPath() const {
    return "/" ~ groupId.replace(".", "/") ~ "/" ~ artifactId ~ "/" ~ ver ~ "/" ~ fileName;
  }

  /// 版本目录的仓库相对路径，e.g. /org/slf4j/slf4j-api/2.0.17
  string dirPath() const {
    return "/" ~ groupId.replace(".", "/") ~ "/" ~ artifactId ~ "/" ~ ver;
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
 * 合并扩展依赖（libs）与基础清单（entry 内置 dependencies/引擎清单）：
 * libs 在前并**覆盖**同名项：同名判定用 `groupId:artifactId`（不看版本/打包/classifier），
 * 同名时整条取 libs 的那条（**版本用 libs 的**），基础清单里的同名项被丢弃，
 * 因此不会出现两个版本并存；与容器侧 `Dependency.Resolver.merge` 的 libs 语义一致。
 * 本地文件/远程 url 用原始行作键。
 */
Archive[] mergeLibraries(Archive[] libs, Archive[] base) {
  Archive[] result = libs.dup;
  bool[string] seen;
  foreach (a; libs) {
    seen[libraryKey(a)] = true;
  }
  foreach (a; base) {
    auto key = libraryKey(a);
    if (key in seen) {
      continue;
    }
    seen[key] = true;
    result ~= a;
  }
  return result;
}

/// 合并去重键：gav 用 group:artifact（对齐 sas `Dependency.Resolver.merge`），其余用原始行。
private string libraryKey(Archive a) {
  if (auto art = cast(Artifact) a) {
    return art.groupId ~ ":" ~ art.artifactId;
  }
  return a.raw;
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
