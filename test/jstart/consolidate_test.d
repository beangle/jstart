/**
 * Unit tests for jstart.consolidate: repo 离线整合：复制 jar+sha1、本地已有跳过、双缺失报告。
 *
 * Test code lives outside of source/, mirroring the beangle micdn
 * layout. It is only compiled by the dub "unittest" configuration,
 * so released binaries never carry test code.
 */
module test.jstart.consolidate_test;

import jstart.archive : Archive, parseGav;
import jstart.consolidate : consolidateArtifacts;
import jstart.repo : LocalRepo;
import std.file : exists;
import std.path : dirName;

unittest {
  import std.conv : to;
  import std.file : dirEntries, isDir, mkdirRecurse, readText, remove, tempDir, write, SpanMode;
  import std.path : buildPath;
  import std.process : thisProcessID;
  import std.string : format;

  import jstart.archive : parseGav;

  void rmTree(string path) {
    if (!exists(path)) {
      return;
    }
    if (isDir(path)) {
      foreach (e; dirEntries(path, SpanMode.shallow)) {
        rmTree(e.name);
      }
    }
    remove(path);
  }

  auto tmpBase = buildPath(tempDir(), "jstart-consolidate-test-" ~ to!string(thisProcessID));
  rmTree(tmpBase);
  mkdirRecurse(tmpBase);
  scope (exit)
    rmTree(tmpBase);
  auto source = new LocalRepo(buildPath(tmpBase, "source"));
  auto target = new LocalRepo(buildPath(tmpBase, "target"));

  // artifact 1: present in source, copied into target
  auto a1 = parseGav("org.test:demo:1.0", "org.test:demo:1.0");
  // artifact 2: already in target, left untouched
  auto a2 = parseGav("org.test:exists:2.0", "org.test:exists:2.0");
  // artifact 3: missing everywhere
  auto a3 = parseGav("org.test:nope:3.0", "org.test:nope:3.0");

  mkdirRecurse(dirName(source.filePath(a1)));
  write(source.filePath(a1), "demo-bytes");
  write(source.filePath(a1.sha1), "deadbeef");
  mkdirRecurse(dirName(target.filePath(a2)));
  write(target.filePath(a2), "existing-bytes");

  Archive[] deps = [a1, a2, a3];
  auto missing = consolidateArtifacts(deps, source, target);

  assert(missing.length == 1, format("missing: %s", missing));
  assert(missing[0] == "org.test:nope:3.0");
  assert(readText(target.filePath(a1)) == "demo-bytes");
  assert(readText(target.filePath(a1.sha1)) == "deadbeef");
  assert(readText(target.filePath(a2)) == "existing-bytes");
  assert(!exists(target.filePath(a3)));
}
