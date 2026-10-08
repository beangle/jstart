/**
 * Maven SNAPSHOT 别名解析：把「不带时间戳的别名」换成实际落盘的时间戳文件。
 *
 * SNAPSHOT 构件在仓库里有两种名字：请求用的别名（`a-1.0-SNAPSHOT.jar`）与落盘用的
 * 时间戳文件（`a-1.0-20260101.010101-2.jar`）。文件名的解析来源有两条：
 *
 *  - micdn 的 `/maven`：HEAD 别名时以 `latest` 响应头回带时间戳文件名；
 *  - 标准 maven 仓库：版本目录下的 `maven-metadata.xml`，`<snapshotVersions>` 里按
 *    extension/classifier 给出 `<value>`（老式元数据则用 `<snapshot>` 的
 *    `<timestamp>`/`<buildNumber>`）。
 *
 * 上半部分是纯解析（文件名、元数据文本、比较）；下半部分 [[fetchSnapshot]] 负责按上游
 * 列表解析并取回本地仓库，`jstart.resolver`（依赖与 gav 目标）与 `jstart.distrepo`
 * （fetch 命令）共用同一实现。
 *
 * 上游没有这类元数据时（例如 micdn 的 `/native`：开发版发行包就是不带时间戳的同名文件，
 * 元数据只有增量补丁才有）返回空串，由调用方按「字面文件」的老路处理。
 */
module jstart.snapshot;

import std.conv : to;
import std.file : exists, remove;
import std.regex : matchAll, regex;
import std.stdio : stderr, writeln;
import std.string : endsWith, indexOf, startsWith, strip;

import jstart.archive : Artifact;
import jstart.http : downloadFile, downloadFileSmart, headHeaders, httpGetText;
import jstart.repo : LocalRepo, RemoteRepo, verifySha1File;

/// SNAPSHOT 版本目录下的元数据文件名（标准 maven 与 micdn 共用）。
enum metadataFileName = "maven-metadata.xml";

/// 时间戳快照文件名解析结果：`{artifactId}-{baseVer}-{timestamp}-{build}[-{classifier}].{packaging}`。
struct SnapshotFile {
  /// yyyyMMdd.HHmmss（构建工具以 UTC 生成）
  string timestamp;
  /// 同一时间戳下递增的构建号
  int build;
  /// 空表示主构件
  string classifier;
  /// 打包后缀（jar/war/tar.gz 等）
  string packaging;
}

/// `yyyyMMdd.HHmmss` 形状校验（maven 时间戳由数字与第 8 位的点构成）。
bool isSnapshotTimestamp(string ts) {
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

/**
 * 解析时间戳快照文件名。`baseVer` 是去掉 `-SNAPSHOT` 的版本基，`packaging` 是期望的
 * 打包后缀（据此把 `-{classifier}` 切出来，故 `.tar.gz` 这类多点后缀也能正确解析）。
 * 形状不合法返回 false。
 */
bool parseSnapshotName(string name, string artifactId, string baseVer, string packaging,
    out SnapshotFile parsed) {
  parsed = SnapshotFile.init;
  auto ext = "." ~ packaging;
  if (!name.endsWith(ext)) {
    return false;
  }
  auto body = name[0 .. $ - ext.length]; // {artifactId}-{baseVer}-{ts}-{build}[-{classifier}]
  auto prefix = artifactId ~ "-" ~ baseVer ~ "-";
  if (!body.startsWith(prefix)) {
    return false;
  }
  auto rest = body[prefix.length .. $];
  auto dash = rest.indexOf("-");
  if (dash < 0 || !isSnapshotTimestamp(rest[0 .. dash])) {
    return false;
  }
  auto afterTs = rest[dash + 1 .. $];
  auto dash2 = afterTs.indexOf("-");
  auto buildText = dash2 < 0 ? afterTs : afterTs[0 .. dash2];
  auto classifier = dash2 < 0 ? "" : afterTs[dash2 + 1 .. $];
  int build = -1;
  try {
    build = to!int(buildText);
  } catch (Exception e) {
    return false;
  }
  if (build < 0) {
    return false;
  }
  parsed = SnapshotFile(rest[0 .. dash], build, classifier, packaging);
  return true;
}

/** 解析 `<snapshotVersions>` 的 `<value>`：`{baseVer}-{ts}-{build}`（不含 classifier）。 */
bool parseSnapshotValue(string value, string baseVer, out SnapshotFile parsed) {
  parsed = SnapshotFile.init;
  auto prefix = baseVer ~ "-";
  if (!value.startsWith(prefix)) {
    return false;
  }
  auto rest = value[prefix.length .. $];
  auto dash = rest.indexOf("-");
  if (dash < 0 || !isSnapshotTimestamp(rest[0 .. dash])) {
    return false;
  }
  int build = -1;
  try {
    build = to!int(rest[dash + 1 .. $]);
  } catch (Exception e) {
    return false;
  }
  if (build < 0) {
    return false;
  }
  parsed = SnapshotFile(rest[0 .. dash], build, "", "");
  return true;
}

/// 按 (时间戳, 构建号) 比较两个快照文件，兼容 `<`/`>` 运算符。
int compareSnapshot(in SnapshotFile a, in SnapshotFile b) {
  if (a.timestamp != b.timestamp) {
    return a.timestamp < b.timestamp ? -1 : 1;
  }
  if (a.build != b.build) {
    return a.build < b.build ? -1 : 1;
  }
  return 0;
}

/**
 * 从 `maven-metadata.xml` 里挑出匹配 extension/classifier 的最新快照值。
 *
 * 优先 `<snapshotVersions>` 里 extension、classifier 都对得上且值形状合法的条目，取
 * (时间戳, 构建号) 最大者；没有这种条目时退回 `<versioning><snapshot>` 的
 * `<timestamp>`/`<buildNumber>` 拼出 `{baseVer}-{ts}-{build}`。解析不出返回空串。
 */
string newestSnapshotValue(string xml, string baseVer, string packaging, string classifier) {
  string best;
  SnapshotFile bestParsed;
  foreach (m; matchAll(xml, regex(`<snapshotVersion\b[^>]*>(.*?)</snapshotVersion>`, "s"))) {
    auto block = m[1];
    if (elementText(block, "extension") != packaging
        || elementText(block, "classifier") != classifier) {
      continue;
    }
    auto value = elementText(block, "value");
    SnapshotFile parsed;
    if (value.length == 0 || !parseSnapshotValue(value, baseVer, parsed)) {
      continue;
    }
    if (best.length == 0 || compareSnapshot(parsed, bestParsed) > 0) {
      best = value;
      bestParsed = parsed;
    }
  }
  if (best.length) {
    return best;
  }
  auto ts = elementText(xml, "timestamp");
  auto buildText = elementText(xml, "buildNumber");
  if (!isSnapshotTimestamp(ts)) {
    return "";
  }
  int build = -1;
  try {
    build = to!int(buildText);
  } catch (Exception e) {
    return "";
  }
  return build < 0 ? "" : baseVer ~ "-" ~ ts ~ "-" ~ to!string(build);
}

/// 取 `<tag>...</tag>` 的文本（无属性、无嵌套，maven-metadata 的机器生成格式够用）。
private string elementText(string xml, string tag) {
  auto open = "<" ~ tag ~ ">";
  auto i = xml.indexOf(open);
  if (i < 0) {
    return "";
  }
  auto start = i + open.length;
  auto end = xml.indexOf("</" ~ tag ~ ">", start);
  return end < 0 ? "" : xml[start .. end].strip;
}

/// [[fetchSnapshot]] 的结果：本地时间戳文件路径、是否为此发生下载、命中的上游。
struct SnapshotFetch {
  /// 本地时间戳文件绝对路径；空表示上游没有元数据且本地也没有时间戳文件。
  string path;
  /// 本次是否下载了构件（false 表示本地已有同一构建，或只是回退本地文件）。
  bool downloaded;
  /// 实际命中的上游地址（回退本地文件时为空）。
  string remote;
}

/** [[fetchSnapshot]] 的 [[RemoteRepo]] 版本（jstart.resolver 用）。 */
SnapshotFetch fetchSnapshot(LocalRepo local, RemoteRepo[] remotes, Artifact a,
    bool verbose = true) {
  string[] bases;
  foreach (r; remotes) {
    bases ~= r.base;
  }
  return fetchSnapshot(local, bases, a, verbose);
}

/**
 * 按上游列表解析 SNAPSHOT 别名到最新时间戳文件，并取回到本地仓库。
 *
 * 逐个上游询问 [[remoteSnapshotFileName]]（HEAD 别名的 `latest` 头，其次版本目录的
 * `maven-metadata.xml`），拿到文件名后：
 *  - 本地已有该时间戳文件且 `.sha1` 通过 → 直接返回，不下载；
 *  - 否则下载构件与 `.sha1`，复核后返回；该上游失败就换下一个。
 *
 * 所有上游都解析不出时退回本地仓库已有的最新时间戳文件（离线可用）。每次调用都会询问
 * 上游（每个 SNAPSHOT 一次 HEAD 或元数据 GET），这样开发版每次都能拿到最新构建；上游
 * 不可达不会导致失败。
 */
SnapshotFetch fetchSnapshot(LocalRepo local, string[] remoteBases, Artifact a,
    bool verbose = true) {
  SnapshotFetch r;
  foreach (base; remoteBases) {
    auto name = remoteSnapshotFileName(base, a, verbose);
    if (name.length == 0) {
      continue;
    }
    auto target = local.snapshotPathFor(a, name);
    if (exists(target) && verifySha1File(target, target ~ ".sha1")) {
      r.path = target;
      return r;
    }
    auto url = base ~ a.dirPath ~ "/" ~ name;
    if (verbose) {
      writeln("Downloading " ~ url);
    }
    if (!downloadFileSmart(url, target, verbose, a.raw)) {
      continue;
    }
    auto sha1Url = url ~ ".sha1";
    if (downloadFile(sha1Url, target ~ ".sha1", false, "")) {
      if (!verifySha1File(target, target ~ ".sha1")) {
        if (verbose) {
          stderr.writeln("Error sha1 for " ~ a.raw ~ ",Remove it.");
        }
        remove(target);
        remove(target ~ ".sha1");
        continue;
      }
    }
    r.path = target;
    r.downloaded = true;
    r.remote = base;
    return r;
  }
  r.path = localSnapshotFile(local, a, verbose);
  return r;
}

/**
 * 本地仓库里该构件的可用文件：优先最新时间戳文件，其次不带时间戳的别名
 * （`a-1.0-SNAPSHOT.jar`，老布局或运维直接放入的文件）。都没有返回空串。
 *
 * 时间戳文件按既有语义直接接受（不查 `.sha1`）；字面别名有 `.sha1` 伴随文件时才校验，
 * 不匹配则删除并视为不可用。
 */
string localSnapshotFile(LocalRepo local, Artifact a, bool verbose = false) {
  auto ts = local.snapshotPathOf(a);
  if (ts.length) {
    if (verbose) {
      writeln("Using local snapshot " ~ ts);
    }
    return ts;
  }
  auto literal = local.snapshotPathFor(a, a.fileName);
  if (!exists(literal)) {
    return "";
  }
  if (!verifySha1File(literal, literal ~ ".sha1")) {
    if (verbose) {
      stderr.writeln("Error sha1 for " ~ a.raw ~ ",Remove it.");
    }
    remove(literal);
    if (exists(literal ~ ".sha1")) {
      remove(literal ~ ".sha1");
    }
    return "";
  }
  if (verbose) {
    writeln("Using local snapshot " ~ literal);
  }
  return literal;
}

/**
 * 询问一个上游，解析出别名对应的最新时间戳文件名；解析不出返回空串。
 * `latest` 头要能解析成与请求 packaging/classifier 完全一致的快照文件名才采纳
 * （避免 `-sources.jar` 之类误配）。
 */
string remoteSnapshotFileName(string base, Artifact a, bool verbose = false) {
  auto head = headHeaders(base ~ a.layoutPath, verbose);
  if (head.ok) {
    auto found = "latest" in head.headers;
    auto latest = found is null ? "" : (*found).strip;
    SnapshotFile parsed;
    if (latest.length
        && parseSnapshotName(latest, a.artifactId, a.baseVersion, a.packaging, parsed)
        && parsed.classifier == a.classifier) {
      return latest;
    }
  }
  string meta;
  if (!httpGetText(base ~ a.dirPath ~ "/" ~ metadataFileName, meta, verbose)) {
    return "";
  }
  auto value = newestSnapshotValue(meta, a.baseVersion, a.packaging, a.classifier);
  if (value.length == 0) {
    return "";
  }
  return a.artifactId ~ "-" ~ value ~ (a.classifier.length ? "-" ~ a.classifier : "")
    ~ "." ~ a.packaging;
}
