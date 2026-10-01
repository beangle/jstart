/**
 * gzip helpers used to rebuild a .tar.gz from a patched tar.
 *
 * Deltas are computed on the uncompressed tar (compressed streams barely
 * diff), so a client has to gunzip the local baseline before applying the
 * patch and gzip the result afterwards. The build plugin packages with the
 * system `tar -z`, whose gzip output is reproducible (`gzip -n -6`), which
 * lets the rebuilt .tar.gz be verified against the published .sha1.
 *
 * Like downloads (curl) and patch decompression (bzip2), the work is
 * delegated to the host command.
 */
module jstart.gzip;

import std.process : spawnProcess, wait;
import std.stdio : File, stderr;

/// Whether the host provides the gzip command.
bool gzipAvailable() {
  try {
    auto input = File("/dev/null", "rb");
    auto output = File("/dev/null", "wb");
    scope (exit) {
      input.close();
      output.close();
    }
    return wait(spawnProcess(["gzip", "--version"], input, output, stderr)) == 0;
  } catch (Exception e) {
    return false;
  }
}

/// Decompress a .gz file into a plain file; false on failure.
bool gunzipTo(string source, string target) {
  return runGzip(["gzip", "-d", "-c", source], target, "");
}

/// Compress a file with `gzip -n -6` (the settings behind `tar -z`); false on failure.
bool gzipTo(string source, string target) {
  return runGzip(["gzip", "-n", "-6", "-c"], target, source);
}

private bool runGzip(string[] args, string target, string input) {
  File output;
  File source;
  try {
    output = File(target, "wb");
    source = input.length ? File(input, "rb") : File("/dev/null", "rb");
  } catch (Exception e) {
    stderr.writeln("Cannot open gzip files: " ~ e.msg);
    return false;
  }
  scope (exit) {
    output.close();
    source.close();
  }
  try {
    return wait(spawnProcess(args, source, output, stderr)) == 0;
  } catch (Exception e) {
    stderr.writeln("Cannot run " ~ args[0] ~ ": " ~ e.msg);
    return false;
  }
}
