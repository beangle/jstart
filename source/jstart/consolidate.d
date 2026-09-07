/**
 * Offline repository consolidation, imitating
 * org.beangle.boot.launcher.Repo of the beangle/boot project.
 *
 * Resolves an application's dependency description and copies the artifacts
 * missing in the target (local) repository from a source repository, so that
 * a machine can start the application fully offline.
 */
module jstart.consolidate;

import std.file : exists, mkdirRecurse;
import std.path : dirName;
import std.stdio : File;

import jstart.archive : Archive, Artifact;
import jstart.repo : LocalRepo;

/** Copy src to dst, creating parent directories; chunked to limit memory. */
private void copyFile(string src, string dst) {
  auto parent = dirName(dst);
  if (parent.length && !exists(parent)) {
    mkdirRecurse(parent);
  }
  auto input = File(src, "rb");
  scope (exit)
    input.close();
  auto output = File(dst, "wb");
  scope (exit)
    output.close();
  foreach (chunk; input.byChunk(1024 * 1024)) {
    output.rawWrite(chunk);
  }
}

/**
 * Copy an artifact and its .sha1 companion from source into target.
 * Returns false when the artifact is not present in the source repository.
 */
bool copyArtifactFrom(Artifact a, LocalRepo source, LocalRepo target) {
  auto src = source.filePath(a);
  if (!exists(src)) {
    return false;
  }
  copyFile(src, target.filePath(a));
  auto sha1 = a.sha1;
  auto srcSha1 = source.filePath(sha1);
  if (exists(srcSha1)) {
    copyFile(srcSha1, target.filePath(sha1));
  }
  return true;
}

/**
 * Copy every artifact referenced by deps and missing in target from source.
 * Returns the raw descriptions of artifacts found in neither repository.
 */
string[] consolidateArtifacts(Archive[] deps, LocalRepo source, LocalRepo target) {
  string[] missing;
  foreach (dep; deps) {
    if (auto a = cast(Artifact) dep) {
      if (exists(target.filePath(a))) {
        continue;
      }
      if (!copyArtifactFrom(a, source, target)) {
        missing ~= dep.raw;
      }
    }
  }
  return missing;
}
