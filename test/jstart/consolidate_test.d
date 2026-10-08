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

unittest {
  // SNAPSHOT：仓库里通常只有带时间戳的构建文件，整合时按最新时间戳原样复制到 target
  // 的同名位置（含 .sha1），再跑一次应视为已存在而不重复复制。
  import std.conv : to;
  import std.file : dirEntries, exists, isDir, mkdirRecurse, readText, remove, tempDir, write, SpanMode;
  import std.path : buildPath;
  import std.process : thisProcessID;

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

  auto tmpBase = buildPath(tempDir(), "jstart-consolidate-snap-" ~ to!string(thisProcessID));
  rmTree(tmpBase);
  mkdirRecurse(tmpBase);
  scope (exit)
    rmTree(tmpBase);
  auto source = new LocalRepo(buildPath(tmpBase, "source"));
  auto target = new LocalRepo(buildPath(tmpBase, "target"));

  auto snap = parseGav("org.test:demo:1.0-SNAPSHOT", "org.test:demo:1.0-SNAPSHOT");
  auto oldFile = source.snapshotPathFor(snap, "demo-1.0-20260101.010101-1.jar");
  auto newFile = source.snapshotPathFor(snap, "demo-1.0-20260102.020202-2.jar");
  mkdirRecurse(source.snapshotDirOf(snap));
  write(oldFile, "old-bytes");
  write(newFile, "new-bytes");
  write(newFile ~ ".sha1", "deadbeef");

  Archive[] deps = [snap];
  auto missing = consolidateArtifacts(deps, source, target);
  assert(missing.length == 0);
  auto copied = target.snapshotPathFor(snap, "demo-1.0-20260102.020202-2.jar");
  assert(exists(copied), "最新时间戳文件应复制到 target");
  assert(readText(copied) == "new-bytes");
  assert(readText(copied ~ ".sha1") == "deadbeef");
  assert(!exists(target.snapshotPathFor(snap, "demo-1.0-20260101.010101-1.jar")),
      "只搬最新构建，不搬历史时间戳");

  // target 已有时间戳文件 → 跳过，不重复复制
  write(copied, "target-bytes");
  missing = consolidateArtifacts(deps, source, target);
  assert(missing.length == 0);
  assert(readText(copied) == "target-bytes", "target 已有快照文件时不应覆盖");
}
