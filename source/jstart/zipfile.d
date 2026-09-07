/**
 * Helpers to read entries out of zip/jar/war archives.
 */
module jstart.zipfile;

import std.file : exists, read;
import std.string : indexOf, split, strip;
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
