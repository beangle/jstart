/**
 * HTTP download helpers based on the host `curl` command, the same approach
 * as the beangle micdn project. No libcurl dependency: a working `curl`
 * binary must be installed on the host.
 *
 * Files are downloaded into a hidden temp file next to the target first and
 * renamed on success, avoiding cross-device renames.
 */
module jstart.http;

import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : exists, getSize, mkdirRecurse, remove, rename;
import std.format : format;
import std.path : baseName, dirName;
import std.process : execute;
import std.stdio : stderr, writeln;
import std.string : strip;

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
