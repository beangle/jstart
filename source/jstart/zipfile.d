/**
 * Helpers to read entries out of and explode zip/jar/war archives.
 */
module jstart.zipfile;

import std.file : exists, read;
import std.algorithm : canFind;
import std.string : endsWith, indexOf, join, split, strip;
import std.zip : ZipArchive;

/// The standard manifest file inside a jar.
enum manifestEntry = "META-INF/MANIFEST.MF";

/**
 * Read and decompress one archive entry; null when the entry is missing
 * or the file is not a valid archive.
 */
ubyte[] readZipEntry(string zipPath, string entryName) {
  if (!exists(zipPath)) {
    return null;
  }
  ZipArchive zip;
  try {
    zip = new ZipArchive(cast(ubyte[]) read(zipPath));
  } catch (Exception e) {
    return null;
  }
  auto wanted = normalizeEntryName(entryName);
  foreach (name, member; zip.directory) {
    if (normalizeEntryName(name) == wanted) {
      try {
        return zip.expand(member);
      } catch (Exception e) {
        return null;
      }
    }
  }
  return null;
}

/** Parse the Main-Class attribute out of a jar manifest; "" when absent. */
string manifestMainClass(string jarPath) {
  auto data = readZipEntry(jarPath, manifestEntry);
  if (data is null || data.length == 0) {
    return "";
  }
  auto text = cast(string) data.idup;
  foreach (lineRaw; text.split("\n")) {
    auto line = lineRaw.strip;
    if (line.length == 0) {
      continue;
    }
    auto colon = line.indexOf(":");
    if (colon <= 0) {
      continue;
    }
    if (line[0 .. colon].strip == "Main-Class") {
      return line[colon + 1 .. $].strip;
    }
  }
  return "";
}

/** Normalize entry names: strip leading slashes and drive prefixes. */
private string normalizeEntryName(string name) {
  auto n = name;
  while (n.length && (n[0] == '/' || n[0] == '\\')) {
    n = n[1 .. $];
  }
  return n;
}

/**
 * Explode a zip archive into destDir (created when missing) and return
 * the number of file entries extracted. Entry names are sanitized: names
 * with backslashes, leading '/' or ".." segments are skipped so nothing
 * can escape destDir; directory entries create the directories.
 */
size_t explodeZip(string zipPath, string destDir) {
  import std.array : split;
  import std.file : mkdirRecurse, write;
  import std.path : buildPath, dirName;

  if (!exists(zipPath)) {
    return 0;
  }
  ZipArchive zip;
  try {
    zip = new ZipArchive(cast(ubyte[]) read(zipPath));
  } catch (Exception e) {
    return 0;
  }
  mkdirRecurse(destDir);
  size_t count;
  foreach (name, member; zip.directory) {
    auto rel = safeEntryName(name);
    if (rel.length == 0) {
      continue;
    }
    auto dest = buildPath(destDir, rel);
    if (name.endsWith("/")) {
      try {
        mkdirRecurse(dest);
      } catch (Exception e) {
        // ignore uncreatable directory entries
      }
      continue;
    }
    try {
      auto data = zip.expand(member);
      mkdirRecurse(dirName(dest));
      write(dest, data);
      count++;
    } catch (Exception e) {
      // skip unreadable or unwritable entries
    }
  }
  return count;
}

/// Sanitize an entry name; "" means the entry must be skipped.
private string safeEntryName(string name) {
  if (name.length == 0 || name[0] == '/' || name.canFind("\\")) {
    return "";
  }
  auto parts = name.split("/");
  string[] clean;
  foreach (part; parts) {
    if (part.length == 0 || part == ".") {
      continue;
    }
    if (part == "..") {
      return "";
    }
    clean ~= part;
  }
  return clean.join("/");
}
