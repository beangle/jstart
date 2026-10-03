/**
 * HTTP download helpers based on the host `curl` command, the same approach
 * as the beangle micdn project. No libcurl dependency: a working `curl`
 * binary must be installed on the host.
 *
 * Files are downloaded into a hidden temp file next to the target first and
 * renamed on success, avoiding cross-device renames.
 */
module jstart.http;

import std.algorithm : canFind;
import std.array : join, split;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : exists, getSize, mkdirRecurse, remove, rename;
import std.format : format;
import std.parallelism : TaskPool;
import std.path : baseName, dirName;
import std.process : Config, environment, execute;
import std.range : iota;
import std.stdio : File, stderr, stdout, writeln;
import std.string : indexOf, startsWith, strip, toLower;

/// Payloads below this size are downloaded with one request.
enum minRangeSize = 1024 * 1024;
/// Upper bound of parallel range requests for one file.
enum maxRangeParts = 4;

/** 认证参数：设置环境变量 `micdn_token` 后，构件 GET 附加 `Authorization: Bearer`。
 *
 * HEAD 探测（`probeHttp` / `remoteExists`）保持匿名——micdn 的 HEAD 与目录列表不受
 * `download-key` 限制，这样没有令牌时也能正常探测与回退。未设置令牌时返回空数组。
 */
private string[] authArgs() {
  auto token = environment.get("micdn_token");
  if (token.length == 0) {
    return [];
  }
  return ["-H", "Authorization: Bearer " ~ token];
}

/// Result of the capability probe of a remote resource.
private struct ProbeResult {
  /// A successful response was received.
  bool ok;
  /// The server advertises Accept-Ranges: bytes.
  bool range;
  /// Content-Length of the last response.
  long length;
}

/** HEAD probe: detects HTTP support and range capability. */
private ProbeResult probeHttp(string url) {
  ProbeResult r;
  auto res = execute([
    "curl", "-sIL", "--connect-timeout", "10", "--max-time", "60", url
  ]);
  if (res.status != 0) {
    return r;
  }
  bool httpOk;
  long length = 0;
  foreach (lineRaw; res.output.split("\n")) {
    auto line = lineRaw.strip;
    if (line.startsWith("HTTP/")) {
      httpOk = line.canFind(" 200") || line.canFind(" 206");
      length = 0;
    } else {
      auto lower = line.toLower;
      if (lower.startsWith("content-length:")) {
        auto v = lower["content-length:".length .. $].strip;
        try {
          length = to!long(v);
        } catch (Exception e) {
          length = 0;
        }
      } else if (lower.startsWith("accept-ranges:")) {
        r.range = lower.canFind("bytes");
      }
    }
  }
  r.ok = httpOk;
  r.length = length;
  return r;
}

/// HEAD 探测结果：最终响应是否 2xx，以及小写化的响应头。
struct HttpHead {
  /// 最后一个响应（重定向跟随之后）为 2xx。
  bool ok;
  /// 小写化的响应头；重定向链上出现过的都会保留，同名后者覆盖前者。
  string[string] headers;
}

/**
 * HEAD 请求并返回响应头（跟随重定向）。用于解析 micdn 的 SNAPSHOT 别名：它在 200
 * 响应里以 `latest: <时间戳文件名>` 回带实际构件名，一次请求即可完成「别名 → 时间戳
 * 文件」的解析，无需下载元数据。
 *
 * HEAD 保持匿名（`authArgs` 只用于 GET）：micdn 的 `<auth download-key>` 不限制 HEAD，
 * 这样没有令牌时探测与回退仍可用。
 */
HttpHead headHeaders(string url, bool verbose = false) {
  HttpHead r;
  auto res = execute([
    "curl", "-s", "-S", "-I", "-L", "--connect-timeout", "10", "--max-time", "60", url
  ]);
  if (res.status != 0) {
    if (verbose) {
      stderr.writeln("Probe failed " ~ url ~ ": " ~ res.output.strip);
    }
    return r;
  }
  int code = 0;
  foreach (lineRaw; res.output.split("\n")) {
    auto line = lineRaw.strip;
    if (line.startsWith("HTTP/")) {
      code = 0;
      auto parts = line.split(" ");
      if (parts.length >= 2) {
        try {
          code = to!int(parts[1]);
        } catch (Exception e) {
          code = 0;
        }
      }
      continue;
    }
    auto colon = line.indexOf(":");
    if (colon <= 0) {
      continue;
    }
    auto key = line[0 .. colon].strip.toLower;
    auto value = line[colon + 1 .. $].strip;
    if (key.length && value.length) {
      r.headers[key] = value;
    }
  }
  r.ok = code >= 200 && code < 300;
  return r;
}

/**
 * GET 一个文本资源（如版本目录下的 `maven-metadata.xml`），成功时把响应体写入 text。
 * 受 `download-key` 保护的仓库要求 GET 带令牌，故沿用 `authArgs`。
 */
bool httpGetText(string url, out string text, bool verbose = false) {
  text = "";
  auto args = [
    "curl", "--fail", "--silent", "--show-error", "-L", "--connect-timeout", "10",
    "--max-time", "60"
  ];
  args ~= authArgs();
  args ~= [url];
  auto res = execute(args);
  if (res.status != 0) {
    if (verbose) {
      stderr.writeln(format("Fetch failed %s (curl exit %d): %s", url, res.status,
          res.output.strip));
    }
    return false;
  }
  text = res.output;
  return true;
}

/**
 * HEAD probe: true when the url answers 2xx (redirects followed). Used to
 * detect optional resources such as binary deltas, where a 404 is a normal
 * outcome rather than an error.
 */
bool remoteExists(string url, bool verbose = false) {
  auto res = execute([
    "curl", "-s", "-S", "-I", "-L", "-o", "/dev/null", "-w", "%{http_code}",
    "--connect-timeout", "10", "--max-time", "60", url
  ]);
  if (res.status != 0) {
    if (verbose) {
      stderr.writeln("Probe failed " ~ url ~ ": " ~ res.output.strip);
    }
    return false;
  }
  return res.output.strip == "200";
}

/**
 * Download url into location. Uses parallel HTTP Range requests when the
 * server supports ranges and the payload is at least minRangeSize; the
 * parts are merged and renamed over location. Falls back to one plain
 * request when the probe fails or a part is corrupted.
 */
bool downloadFileSmart(string url, string location, bool verbose = true,
    string label = "") {
  auto probe = probeHttp(url);
  if (!probe.ok || !probe.range || probe.length < minRangeSize) {
    return downloadFile(url, location, verbose, label);
  }
  auto parent = dirName(location);
  if (parent.length && !exists(parent)) {
    try {
      mkdirRecurse(parent);
    } catch (Exception e) {
      return false;
    }
  }
  auto base = baseName(location);
  long parts = (probe.length + minRangeSize - 1) / minRangeSize;
  if (parts > maxRangeParts) {
    parts = maxRangeParts;
  }
  if (parts < 2) {
    return downloadFile(url, location, verbose, label);
  }

  auto tmpPath = parent ~ "/." ~ base ~ ".part";
  scope (exit) {
    if (exists(tmpPath)) {
      remove(tmpPath);
    }
  }
  auto step = probe.length / parts;
  auto partPaths = new string[parts];
  scope (exit) {
    foreach (p; partPaths) {
      if (p.length && exists(p)) {
        remove(p);
      }
    }
  }
  auto ok = new bool[parts];
  auto expected = new long[parts];
  auto sw = StopWatch(AutoStart.yes);
  auto pool = new TaskPool(cast(size_t) parts);
  scope (exit) pool.stop();
  foreach (i; pool.parallel(iota(parts))) {
    auto start = i * step;
    auto end = (i == parts - 1) ? probe.length - 1 : start + step - 1;
    expected[i] = end - start + 1;
    auto partPath = parent ~ "/." ~ base ~ ".part." ~ to!string(i);
    partPaths[i] = partPath;
    auto args = [
      "curl", "--fail", "--silent", "--show-error", "-L", "--connect-timeout",
      "10", "--max-time", "300", "--speed-time", "30", "--speed-limit", "1024",
      "-r", to!string(start) ~ "-" ~ to!string(end), "-o", partPath,
    ];
    args ~= authArgs();
    args ~= [url];
    auto res = execute(args);
    ok[i] = res.status == 0 && exists(partPath) && getSize(partPath) == expected[i];
  }
  sw.stop();
  foreach (i; 0 .. parts) {
    if (!ok[i]) {
      return downloadFile(url, location, verbose, label); // 清理后回退单请求
    }
  }
  // Merge parts in order into the .part temp file.
  File output;
  try {
    output = File(tmpPath, "wb");
    foreach (p; partPaths) {
      auto input = File(p, "rb");
      scope (exit) input.close();
      foreach (chunk; input.byChunk(1024 * 1024)) {
        output.rawWrite(chunk);
      }
    }
  } finally {
    output.close(); // flush + close, size 检查必须发生在落盘之后
  }
  if (!exists(tmpPath) || getSize(tmpPath) != probe.length) {
    return downloadFile(url, location, verbose, label);
  }
  if (exists(location)) {
    remove(location);
  }
  rename(tmpPath, location);
  if (verbose) {
    auto prefix = label.length ? label ~ " " : "";
    writeln(format("%sDownloaded %s (%d bytes, %.1fs, %d ranges)", prefix,
        url, getSize(location), sw.peek.total!"seconds", parts));
  }
  return true;
}

/**
 * Download url into location with the curl command.
 * Returns false on any failure; verbose controls the messages.
 */
bool downloadFile(string url, string location, bool verbose = true, string label = "") {
  auto parent = dirName(location);
  if (parent.length && !exists(parent)) {
    try {
      mkdirRecurse(parent);
    } catch (Exception e) {
      return false;
    }
  }
  auto tmpPath = parent ~ "/." ~ baseName(location) ~ ".part";
  scope (exit) {
    if (exists(tmpPath)) {
      remove(tmpPath);
    }
  }

  auto sw = StopWatch(AutoStart.yes);
  auto args = [
    "curl", "--fail", "--silent", "--show-error", "-L", "--connect-timeout", "10",
    "--max-time", "300", "--speed-time", "30", "--speed-limit", "1024", "-o",
    tmpPath
  ];
  args ~= authArgs();
  args ~= [url];
  auto result = execute(args);
  sw.stop();
  if (result.status != 0) {
    if (verbose) {
      auto detail = result.output.strip;
      if (detail.length) {
        stderr.writeln(format("Download failed %s (curl exit %d): %s", url, result.status, detail));
      } else {
        stderr.writeln(format("Download failed %s (curl exit %d)", url, result.status));
      }
    }
    return false;
  }
  if (!exists(tmpPath)) {
    if (verbose) {
      stderr.writeln("Download failed " ~ url ~ ": temp file missing after download");
    }
    return false;
  }
  if (exists(location)) {
    remove(location);
  }
  rename(tmpPath, location);
  if (verbose) {
    auto prefix = label.length ? label ~ " " : "";
    writeln(format("%sDownloaded %s (%d bytes, %.1fs)", prefix, url,
        getSize(location), sw.peek.total!"seconds"));
  }
  return true;
}

/// Result of running a helper process whose stdout is captured.
struct ProcResult {
  /// Exit status (negative signal number when killed, per std.process.wait).
  int status;
  /// Everything the child wrote to stdout; stderr is passed through.
  string stdoutText;
}

/**
 * Run a command and capture its stdout while forwarding stderr to the
 * parent's stderr (Config.stderrPassThrough). Used to run an engine entry
 * main, which writes the real launch command to a file and may print
 * diagnostics to stderr; its stdout is captured (and only shown when
 * verbose) so it cannot pollute jstart's own output.
 */
ProcResult runProcessCapture(string[] cmd, bool verbose = false) {
  if (verbose) {
    writeln("Running " ~ cmd.join(" "));
    stdout.flush();
    stderr.flush();
  }
  try {
    auto res = execute(cmd, null, Config.stderrPassThrough);
    return ProcResult(res.status, res.output);
  } catch (Exception e) {
    stderr.writeln("Cannot run " ~ cmd[0] ~ ": " ~ e.msg);
    return ProcResult(127, "");
  }
}
