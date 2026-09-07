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
import std.array : split;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : exists, getSize, mkdirRecurse, remove, rename;
import std.format : format;
import std.parallelism : TaskPool;
import std.path : baseName, dirName;
import std.process : execute;
import std.range : iota;
import std.stdio : File, stderr, writeln;
import std.string : startsWith, strip, toLower;

/// Payloads below this size are downloaded with one request.
enum minRangeSize = 1024 * 1024;
/// Upper bound of parallel range requests for one file.
enum maxRangeParts = 4;

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
    auto res = execute([
      "curl", "--fail", "--silent", "--show-error", "-L", "--connect-timeout",
      "10", "--max-time", "300", "--speed-time", "30", "--speed-limit", "1024",
      "-r", to!string(start) ~ "-" ~ to!string(end), "-o", partPath,
      url
    ]);
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
  auto result = execute([
    "curl", "--fail", "--silent", "--show-error", "-L", "--connect-timeout", "10",
    "--max-time", "300", "--speed-time", "30", "--speed-limit", "1024", "-o",
    tmpPath, url
  ]);
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
