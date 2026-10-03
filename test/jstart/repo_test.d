/**
 * Unit tests for jstart.repo: 本地仓库路径展开、sha1 文本解析、远程列表（普通构件追加
 * Central；SNAPSHOT 的上游不追加、无默认）。
 *
 * Test code lives outside of source/, mirroring the beangle micdn
 * layout. It is only compiled by the dub "unittest" configuration,
 * so released binaries never carry test code.
 */
module test.jstart.repo_test;

import jstart.repo : LocalRepo, buildRemotes, buildSnapshotRemotes, parseSha1Text;
import std.process : environment;

unittest {
  auto local = new LocalRepo("~");
  assert(local.base == environment.get("HOME"));

  assert(parseSha1Text("da39a3ee5e6b4b0d3255bfef95601890afd80709  a.txt\n")
      == "da39a3ee5e6b4b0d3255bfef95601890afd80709");
  assert(parseSha1Text("") == "");

  // remotes always end with central
  auto remotes = buildRemotes("https://repo.example.com/maven2");
  assert(remotes.length == 2);
  assert(remotes[0].base == "https://repo.example.com/maven2");
  assert(remotes[1].base == "https://repo1.maven.org/maven2");

  auto one = buildRemotes("https://repo1.maven.org/maven2");
  assert(one.length == 1);

  auto defaults = buildRemotes();
  assert(defaults.length == 3);

  // SNAPSHOT 上游不追加 Central、不给默认镜像：只用显式给出的列表
  assert(buildSnapshotRemotes().length == 0);
  assert(buildSnapshotRemotes("").length == 0);
  auto snapRemotes = buildSnapshotRemotes("https://repo.example.com/snapshots");
  assert(snapRemotes.length == 1);
  assert(snapRemotes[0].base == "https://repo.example.com/snapshots");
  auto two = buildSnapshotRemotes("http://a/maven, https://b/maven/");
  assert(two.length == 2);
  assert(two[0].base == "http://a/maven" && two[1].base == "https://b/maven");
}

unittest {
  import std.conv : to;
  import std.file : dirEntries, exists, isDir, mkdirRecurse, remove, tempDir,
    write, SpanMode;
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

  auto tmpBase = buildPath(tempDir(), "jstart-snapshot-test-" ~ to!string(thisProcessID));
  rmTree(tmpBase);
  mkdirRecurse(tmpBase);
  scope (exit) rmTree(tmpBase);

  auto repo = new LocalRepo(tmpBase);
  auto dir = buildPath(tmpBase, "org/test/demo/1.0-SNAPSHOT");
  mkdirRecurse(dir);
  write(buildPath(dir, "demo-1.0-20260101.010101-1.jar"), "old");
  write(buildPath(dir, "demo-1.0-20260101.010101-2.jar"), "new");

  auto snap = parseGav("org.test:demo:1.0-SNAPSHOT", "org.test:demo:1.0-SNAPSHOT");
  assert(repo.snapshotPathOf(snap) == buildPath(dir, "demo-1.0-20260101.010101-2.jar"));

  // 非 SNAPSHOT 或无效时间戳文件名不参与
  auto rel = parseGav("org.test:demo:1.0", "org.test:demo:1.0");
  assert(repo.snapshotPathOf(rel).length == 0);
  write(buildPath(dir, "demo-1.0-notimestamp.jar"), "x");
  assert(repo.snapshotPathOf(snap) == buildPath(dir, "demo-1.0-20260101.010101-2.jar"));
}
