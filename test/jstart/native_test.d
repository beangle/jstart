/**
 * Unit tests for jstart.native: tar.gz target detection, cached extraction and
 * executable discovery inside a native (GraalVM) distribution.
 *
 * Test code lives outside of source/, mirroring the beangle micdn layout.
 */
module test.jstart.native_test;

import std.algorithm : canFind, endsWith;
import std.conv : to;
import std.file : dirEntries, exists, isDir, mkdirRecurse, remove, SpanMode, tempDir, write;
import std.path : baseName, buildPath;
import std.process : execute, thisProcessID;
import std.string : startsWith;

import jstart.native : Extraction, extractTarGz, findExecutable, isNativeTarget,
  isTarGzPackaging, tarAvailable, targetGav;

private void rmTree(string path) {
  if (!exists(path)) {
    return;
  }
  foreach (e; dirEntries(path, SpanMode.depth)) {
    remove(e.name);
  }
  if (exists(path)) {
    remove(path);
  }
}

/**
 * Build a `<name>/bin/<exe>` + `<name>/lib/...` distribution and pack it as
 * tar.gz, the layout produced for beangle native-image builds.
 */
private string makeDistribution(string tmp, string name, string exeName, string mode) {
  auto src = buildPath(tmp, "src-" ~ name);
  rmTree(src);
  auto binDir = buildPath(src, name, "bin");
  auto libDir = buildPath(src, name, "lib");
  mkdirRecurse(binDir);
  mkdirRecurse(libDir);
  auto exe = buildPath(binDir, exeName);
  write(exe, cast(ubyte[]) "#!/bin/sh\necho native\n");
  write(buildPath(libDir, "libmain.so"), cast(ubyte[]) "so");
  assert(execute(["chmod", mode, exe]).status == 0);
  auto archive = buildPath(tmp, name ~ ".tar.gz");
  auto tar = execute(["tar", "-czf", archive, "-C", src, name]);
  assert(tar.status == 0, tar.output);
  return archive;
}

/// Pack a directory tree as an archive without a single top-level directory.
private string makeFlatTarGz(string tmp, string archiveStem, string[] files, string mode) {
  auto src = buildPath(tmp, "src-" ~ archiveStem);
  rmTree(src);
  mkdirRecurse(buildPath(src, "bin"));
  foreach (f; files) {
    auto p = buildPath(src, f);
    write(p, cast(ubyte[]) "#!/bin/sh\necho flat\n");
    assert(execute(["chmod", mode, p]).status == 0);
  }
  auto archive = buildPath(tmp, archiveStem ~ ".tar.gz");
  auto tar = execute(["tar", "-czf", archive, "-C", src, "."]);
  assert(tar.status == 0, tar.output);
  return archive;
}

unittest {
  assert(isTarGzPackaging("tar.gz") && isTarGzPackaging("tgz"));
  assert(!isTarGzPackaging("jar") && !isTarGzPackaging("tar"));

  assert(targetGav("org.example:demo:tar.gz:linux-amd64:1.0")
      == "org.example:demo:tar.gz:linux-amd64:1.0");
  assert(targetGav("gav://org.example:demo:1.0") == "org.example:demo:1.0");
  assert(targetGav("/tmp/demo.tar.gz") == "");
  assert(targetGav("https://host/demo.tar.gz") == "");

  assert(isNativeTarget("org.example:demo:tar.gz:linux-amd64:1.0"));
  assert(isNativeTarget("gav://org.example:demo:tgz:linux-amd64:1.0"));
  assert(isNativeTarget("/tmp/demo-1.0-linux-amd64.tar.gz"));
  assert(isNativeTarget("https://host/demo.tgz"));
  assert(!isNativeTarget("org.example:demo:1.0"));
  assert(!isNativeTarget("/tmp/demo.war"));
}

unittest {
  if (!tarAvailable()) {
    return; // 提取依赖宿主 tar 命令：没有就跳过
  }
  auto tmp = buildPath(tempDir(), "jstart-native-test-" ~ to!string(thisProcessID));
  rmTree(tmp);
  mkdirRecurse(tmp);
  scope (exit) rmTree(tmp);

  auto name = "demo-1.0-linux-amd64";
  auto archive = makeDistribution(tmp, name, "demo", "755");
  auto dir = buildPath(tmp, "app");

  // 解压到调用方给的目录（run 传 <base>/app）：<name>/bin/demo 布局，按 artifactId 命中
  auto first = extractTarGz(archive, false, false, dir);
  assert(first.ok && !first.reused);
  assert(first.dir == dir);
  // 标记文件在解压目录内（.jstart.stamp）：目录与标记总是同时可见
  assert(exists(buildPath(first.dir, ".jstart.stamp")));
  assert(!exists(first.dir ~ ".stamp"));
  // 除标记文件外，解压目录顶层只有发行包内容（顶层只能有一个目录）
  auto topEntries = 0;
  foreach (e; dirEntries(first.dir, SpanMode.shallow)) {
    if (!e.name.baseName.startsWith(".")) {
      topEntries++;
    }
  }
  assert(topEntries == 1);
  string[] candidates;
  auto found = findExecutable(first.dir, "", "demo", candidates);
  assert(found == buildPath(first.dir, name, "bin", "demo"), found);
  assert(execute(["test", "-x", found]).status == 0);

  // 复用：标记匹配时不重解，目录内容原样保留
  auto keep = buildPath(first.dir, "keep");
  write(keep, "x");
  auto second = extractTarGz(archive, false, false, dir);
  assert(second.ok && second.reused);
  assert(exists(keep));

  // force：强制重解，上一次的残留被清掉
  auto forced = extractTarGz(archive, false, true, dir);
  assert(forced.ok && !forced.reused);
  assert(!exists(keep));

  // 显式 [app] exec 提示优先
  assert(findExecutable(first.dir, name ~ "/bin/demo", "", candidates)
      == buildPath(first.dir, name, "bin", "demo"));
  assert(findExecutable(first.dir, "bin/does-not-exist", "", candidates) == "");

  // 打包时丢了执行位：bin/ 下唯一常规文件仍然可用（补上执行位）
  auto noExec = makeDistribution(tmp, "noexec-1.0", "noexec", "644");
  auto noExecEx = extractTarGz(noExec, false, false, buildPath(tmp, "noexec-app"));
  assert(noExecEx.ok);
  auto noExecFound = findExecutable(noExecEx.dir, "", "", candidates);
  assert(noExecFound.endsWith("bin/noexec"), noExecFound);
  assert(execute(["test", "-x", noExecFound]).status == 0);

  // 没有顶层目录的布局：bin/<exe> 直接在解压根
  auto flat = makeFlatTarGz(tmp, "flat-1.0", ["bin/tool"], "755");
  auto flatDir = buildPath(tmp, "flat-app");
  auto flatEx = extractTarGz(flat, false, false, flatDir);
  assert(flatEx.ok && flatEx.dir == flatDir);
  assert(findExecutable(flatEx.dir, "", "", candidates).endsWith("bin/tool"));

  // 多个可执行文件且无法判定：返回空并给出候选，供调用方提示
  auto many = makeFlatTarGz(tmp, "many-1.0", ["bin/one", "bin/two"], "755");
  auto manyEx = extractTarGz(many, false, false, buildPath(tmp, "many-app"));
  assert(manyEx.ok);
  candidates = null;
  assert(findExecutable(manyEx.dir, "", "", candidates) == "");
  assert(candidates.length == 2);
  assert(candidates[0].endsWith("bin/one") && candidates[1].endsWith("bin/two"));

  // 同名目录已存在且不是 jstart 解压产物（无标记）：拒绝覆盖，用户数据原样保留
  auto guarded = makeDistribution(tmp, "guarded-1.0", "guarded", "755");
  auto guardedDir = buildPath(tmp, "guarded-app");
  mkdirRecurse(guardedDir);
  auto sentinel = buildPath(guardedDir, "user-data");
  write(sentinel, "keep me");
  auto refused = extractTarGz(guarded, false, false, guardedDir);
  assert(!refused.ok);
  assert(exists(sentinel));

  // 空目标目录：明确报错而不是回退到包旁
  assert(!extractTarGz(guarded, false, false, "").ok);

  // 不会写到包旁（发行包所在的临时目录里只应有 src-/归档本身）
  assert(!exists(buildPath(tmp, name)));
  assert(!exists(buildPath(tmp, name) ~ ".stamp"));
}

unittest {
  // 并发解压同一归档：一份工件多副本同时启动时不互相踩踏
  if (!tarAvailable()) {
    return;
  }
  auto tmp = buildPath(tempDir(), "jstart-native-conc-" ~ to!string(thisProcessID));
  rmTree(tmp);
  mkdirRecurse(tmp);
  scope (exit) rmTree(tmp);

  auto dir = buildPath(tmp, "app");
  auto archive = makeDistribution(tmp, "conc-1.0", "conc", "755");
  import core.thread : Thread;

  // D 的闭包按函数帧捕获，循环变量会被两个线程共用：显式分开两次调用
  Extraction first0;
  Extraction first1;
  auto slot0 = &first0;
  auto slot1 = &first1;
  auto t0 = new Thread({
    *slot0 = extractTarGz(archive, false, false, dir);
  });
  auto t1 = new Thread({
    *slot1 = extractTarGz(archive, false, false, dir);
  });
  t0.start();
  t1.start();
  t0.join();
  t1.join();
  auto results = [first0, first1];

  assert(results[0].ok && results[1].ok);
  assert(results[0].dir == results[1].dir);
  assert(exists(buildPath(results[0].dir, "conc-1.0", "bin", "conc")));
  // 中间产物（临时/旧目录）都已清理
  foreach (e; dirEntries(tmp, SpanMode.shallow)) {
    assert(!e.name.baseName.canFind(".tmp-") && !e.name.baseName.canFind(".old-"), e.name);
  }
}
