/**
 * Unit tests for jstart.distrepo: dist url/delta naming, baseline inference,
 * snapshot lookup with classifier, and an end-to-end fetch against a local
 * static server (delta probe -> bspatch -> gzip -> sha1 verification).
 *
 * Test code lives outside of source/, mirroring the beangle micdn layout.
 */
module test.jstart.fetch_test;

import core.thread : Thread;
import core.time : msecs;
import std.algorithm : canFind;
import std.array : split;
import std.conv : to;
import std.file : exists, mkdirRecurse, read, readText, remove, tempDir, write,
  SpanMode, dirEntries;
import std.path : buildPath, dirName;
import std.process : environment, execute, thisProcessID;
import std.socket : AddressFamily, InternetAddress, Socket, SocketType;
import std.string : indexOf, replace, startsWith, strip, toLower;

import jstart.archive : parseGav;
import jstart.bspatch : applyBsdiff, bspatchAvailable, systemBspatchPath;
import jstart.distrepo : buildDistRemotes, compareVersion, defaultDistRemote,
  deltaFileName, deltaUrl, distUrl, fetchDist, findLocalArtifact,
  inferBaselineVersion;
import jstart.repo : LocalRepo, sha1OfFile;

/// Static file server: GET/HEAD from a root directory, no ranges, no keep-alive.
private final class StaticServer {
  Socket listener;
  ushort port;
  string root;
  private bool stopped;
  private Thread worker;

  this(string root) {
    this.root = root;
  }

  void start() {
    listener = new Socket(AddressFamily.INET, SocketType.STREAM);
    listener.bind(new InternetAddress("127.0.0.1", 0));
    listener.listen(16);
    port = (cast(InternetAddress) listener.localAddress).port;
    worker = new Thread(&acceptLoop);
    worker.start();
  }

  void stop() {
    stopped = true;
    if (listener !is null) {
      try {
        listener.close();
      } catch (Exception e) {
      }
    }
    if (worker !is null) {
      try {
        worker.join();
      } catch (Exception e) {
      }
    }
  }

  private void acceptLoop() {
    listener.blocking = false;
    while (!stopped) {
      Socket s;
      try {
        s = listener.accept();
      } catch (Exception e) {
        Thread.sleep(5.msecs);
        continue;
      }
      handle(s);
    }
  }

  private void handle(Socket s) {
    scope (exit) s.close();
    string head;
    ubyte[8192] buf;
    while (head.indexOf("\r\n\r\n") < 0) {
      auto n = s.receive(buf[]);
      if (n <= 0) {
        return;
      }
      head ~= cast(string) buf[0 .. n];
      if (head.length > 65536) {
        return;
      }
    }
    auto parts = head[0 .. head.indexOf("\r\n")].split(" ");
    if (parts.length < 2) {
      return;
    }
    auto isGet = parts[0] == "GET";
    auto path = parts[1].split("?")[0];
    auto file = root ~ path;
    if (!exists(file)) {
      sendAll(s, cast(ubyte[]) "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
      return;
    }
    auto body = cast(ubyte[]) read(file);
    auto header = "HTTP/1.1 200 OK\r\nContent-Length: " ~ to!string(body.length)
      ~ "\r\nConnection: close\r\n\r\n";
    sendAll(s, cast(ubyte[]) header);
    if (isGet && body.length) {
      sendAll(s, body);
    }
  }

  private static void sendAll(Socket s, ubyte[] data) {
    auto off = 0;
    while (off < data.length) {
      auto n = s.send(data[off .. $]);
      if (n <= 0) {
        return;
      }
      off += n;
    }
  }
}

/// gzip -n -6, the settings behind the published .tar.gz files.
private string gzipFile(string source, string target) {
  auto r = execute(["gzip", "-n", "-6", "-c", source]);
  assert(r.status == 0, "gzip failed: " ~ r.output);
  write(target, cast(ubyte[]) r.output);
  return target;
}

/// bzip2 compressed bytes, as used inside a BSDIFF40 patch.
private ubyte[] bzip2Bytes(ubyte[] data) {
  auto plain = tempDir() ~ "/jstart-fetch-test-bz2-" ~ to!string(thisProcessID);
  write(plain, data);
  scope (exit) {
    if (exists(plain)) {
      remove(plain);
    }
  }
  auto r = execute(["bzip2", "-z", "-c", plain]);
  assert(r.status == 0, "bzip2 failed: " ~ r.output);
  return cast(ubyte[]) r.output.dup;
}

/// bsdiff "off_t": 7 magnitude bytes big-endian, sign in the top bit of byte 7.
private ubyte[] offtout(long value) {
  ubyte[] buf = new ubyte[8];
  auto y = value < 0 ? -value : value;
  foreach (i; 0 .. 7) {
    buf[i] = cast(ubyte)(y % 256);
    y /= 256;
  }
  if (value < 0) {
    buf[7] |= 0x80;
  }
  return buf;
}

/**
 * Craft a patch turning `oldData` into `newData` using the layout
 * new = old[0..5] + "XYZ" + old[5..7] (both fixtures are 10 bytes).
 */
private ubyte[] craftPatch() {
  ubyte[] control;
  control ~= offtout(5) ~ offtout(3) ~ offtout(0); // diff 5, extra 3, seek 0
  control ~= offtout(2) ~ offtout(0) ~ offtout(0); // diff 2, extra 0, seek 0
  auto controlBz = bzip2Bytes(control);
  auto diffBz = bzip2Bytes(new ubyte[7]);
  auto extraBz = bzip2Bytes(cast(ubyte[]) "XYZ");
  ubyte[] patch;
  patch ~= cast(ubyte[]) "BSDIFF40";
  patch ~= offtout(controlBz.length);
  patch ~= offtout(diffBz.length);
  patch ~= offtout(10);
  patch ~= controlBz ~ diffBz ~ extraBz;
  return patch;
}

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

unittest {
  auto a = parseGav("org.example:demo:tar.gz:linux-amd64:2.0-SNAPSHOT",
      "org.example:demo:tar.gz:linux-amd64:2.0-SNAPSHOT");
  assert(distUrl("https://repo.example.com/native", a)
      == "https://repo.example.com/native/org/example/demo/2.0-SNAPSHOT/demo-2.0-SNAPSHOT-linux-amd64.tar.gz");
  assert(deltaFileName(a, "1.0") == "demo-1.0_2.0-SNAPSHOT-linux-amd64.tar.gz.diff");
  auto jar = parseGav("org.example:demo:jar:linux-amd64:2.0-SNAPSHOT",
      "org.example:demo:jar:linux-amd64:2.0-SNAPSHOT");
  assert(deltaFileName(jar, "1.0") == "demo-1.0_2.0-SNAPSHOT.jar.diff");
  // 普通 jar/war 的补丁名不带 classifier（maven 侧命名）
  auto war = parseGav("org.example:demo:war:2.0", "org.example:demo:war:2.0");
  assert(deltaFileName(war, "1.0") == "demo-1.0_2.0.war.diff");
  assert(deltaUrl("https://repo.example.com/m2", war, "1.0")
      == "https://repo.example.com/m2/org/example/demo/2.0/demo-1.0_2.0.war.diff");
  assert(deltaUrl("https://repo.example.com/native", a, "1.0")
      == "https://repo.example.com/native/org/example/demo/2.0-SNAPSHOT/demo-1.0_2.0-SNAPSHOT-linux-amd64.tar.gz.diff");

  assert(buildDistRemotes().length == 1 && buildDistRemotes()[0] == defaultDistRemote);
  auto custom = buildDistRemotes("https://a.example.com//,https://b.example.com");
  assert(custom == ["https://a.example.com", "https://b.example.com"]);

  assert(compareVersion("4.20.9", "4.20.13") < 0);
  assert(compareVersion("4.20.13", "4.20.13") == 0);
  assert(compareVersion("4.20.13", "4.20.14-SNAPSHOT") < 0);
  assert(compareVersion("4.20.14-SNAPSHOT", "4.20.14") > 0);
  assert(compareVersion("4.20.14", "4.20.14-SNAPSHOT") < 0);
}

unittest {
  auto tmp = buildPath(tempDir(), "jstart-fetch-unit-" ~ to!string(thisProcessID));
  rmTree(tmp);
  mkdirRecurse(tmp);
  scope (exit) rmTree(tmp);

  auto local = new LocalRepo(tmp);
  auto a = parseGav("org.example:demo:tar.gz:linux-amd64:2.0-SNAPSHOT",
      "org.example:demo:tar.gz:linux-amd64:2.0-SNAPSHOT");
  auto dir = buildPath(tmp, "org/example/demo");
  mkdirRecurse(buildPath(dir, "1.0"));
  mkdirRecurse(buildPath(dir, "1.5"));
  mkdirRecurse(buildPath(dir, "2.0-SNAPSHOT"));
  write(buildPath(dir, "1.0/demo-1.0-linux-amd64.tar.gz"), "one");
  write(buildPath(dir, "1.5/demo-1.5-linux-amd64.tar.gz"), "one-five");
  write(buildPath(dir, "2.0-SNAPSHOT/demo-2.0-SNAPSHOT-linux-amd64.tar.gz"), "two");
  assert(inferBaselineVersion(local, a) == "1.5");

  // SNAPSHOT 时间戳命中快照库（带 classifier）
  auto snapDir = buildPath(tmp, "org/example/demo/2.0-SNAPSHOT");
  write(buildPath(snapDir, "demo-2.0-20260101.010101-1-linux-amd64.tar.gz"), "snap");
  assert(findLocalArtifact(local, a, false)
      == buildPath(snapDir, "demo-2.0-20260101.010101-1-linux-amd64.tar.gz"));
}

unittest {
  auto tmp = buildPath(tempDir(), "jstart-fetch-e2e-" ~ to!string(thisProcessID));
  rmTree(tmp);
  auto remote = buildPath(tmp, "remote");
  auto versionDir = buildPath(remote, "org/example/demo/2.0-SNAPSHOT");
  auto localBase = buildPath(tmp, "repository");
  auto snapBase = buildPath(tmp, "snapshots");
  mkdirRecurse(versionDir);
  mkdirRecurse(buildPath(localBase, "org/example/demo/1.0"));
  scope (exit) rmTree(tmp);

  // 旧/新 tar（补丁比对的是解压后的 tar）
  auto oldTar = buildPath(tmp, "old.tar");
  auto newTar = buildPath(tmp, "new.tar");
  write(oldTar, cast(ubyte[]) "abcdefghij");
  write(newTar, cast(ubyte[]) "abcdeXYZfg");
  auto oldGz = gzipFile(oldTar, buildPath(tmp, "old.tar.gz"));
  auto newGz = gzipFile(newTar, buildPath(tmp, "new.tar.gz"));
  write(buildPath(localBase, "org/example/demo/1.0/demo-1.0-linux-amd64.tar.gz"), cast(ubyte[]) read(oldGz));

  // 远端：新包 + .sha1 + 增量补丁（别名，无时间戳）
  write(buildPath(versionDir, "demo-2.0-SNAPSHOT-linux-amd64.tar.gz"), cast(ubyte[]) read(newGz));
  write(buildPath(versionDir, "demo-2.0-SNAPSHOT-linux-amd64.tar.gz.sha1"), sha1OfFile(newGz));
  write(buildPath(versionDir, "demo-1.0_2.0-SNAPSHOT-linux-amd64.tar.gz.diff"), craftPatch());

  auto server = new StaticServer(remote);
  server.start();
  scope (exit) server.stop();
  auto base = "http://127.0.0.1:" ~ to!string(server.port);

  // tar.gz + 有补丁：gunzip -> bspatch -> gzip -n -6，结果与发布的 sha1 一致
  auto r = fetchDist("org.example:demo:tar.gz:linux-amd64:2.0-SNAPSHOT", "1.0",
      base, localBase, false, snapBase);
  assert(r.ok);
  assert(r.viaDelta);
  auto target = buildPath(snapBase, "org/example/demo/2.0-SNAPSHOT/demo-2.0-SNAPSHOT-linux-amd64.tar.gz");
  assert(r.path == target);
  auto published = readText(buildPath(versionDir, "demo-2.0-SNAPSHOT-linux-amd64.tar.gz.sha1")).strip;
  assert(published == sha1OfFile(target));

  // 无补丁：直接整包下载（同一个版本目录，换个基线版本）
  rmTree(buildPath(snapBase, "org/example/demo/2.0-SNAPSHOT"));
  auto r2 = fetchDist("org.example:demo:tar.gz:linux-amd64:2.0-SNAPSHOT", "0.9",
      base, localBase, false, snapBase);
  assert(r2.ok);
  assert(!r2.viaDelta);
  assert(!r2.reused);

  // jar：补丁直接作用于构件本身（无需解压/压缩）
  auto jarDir = buildPath(remote, "org/example/demo/3.0-SNAPSHOT");
  mkdirRecurse(jarDir);
  write(buildPath(localBase, "org/example/demo/1.0/demo-1.0-linux-amd64.jar"), cast(ubyte[]) "abcdefghij");
  write(buildPath(jarDir, "demo-3.0-SNAPSHOT-linux-amd64.jar"), cast(ubyte[]) "abcdeXYZfg");
  write(buildPath(jarDir, "demo-3.0-SNAPSHOT-linux-amd64.jar.sha1"),
      sha1OfFile(buildPath(jarDir, "demo-3.0-SNAPSHOT-linux-amd64.jar")));
  write(buildPath(jarDir, "demo-1.0_3.0-SNAPSHOT.jar.diff"), craftPatch());
  auto r3 = fetchDist("org.example:demo:jar:linux-amd64:3.0-SNAPSHOT", "1.0",
      base, localBase, false, snapBase);
  assert(r3.ok);
  assert(r3.viaDelta);
  auto jarTarget = buildPath(snapBase, "org/example/demo/3.0-SNAPSHOT/demo-3.0-SNAPSHOT-linux-amd64.jar");
  assert(r3.path == jarTarget);
  assert(cast(string) read(jarTarget) == "abcdeXYZfg");

  // 二次运行命中本地（快照库里的字面文件），不再下载
  auto r4 = fetchDist("org.example:demo:jar:linux-amd64:3.0-SNAPSHOT", "1.0",
      base, localBase, false, snapBase);
  assert(r4.ok && r4.reused && !r4.viaDelta);
}

/// bspatch 的取用顺序：系统命令优先（用脚本模拟），失败/尺寸不符回退内置实现。
unittest {
  import std.file : setAttributes, getAttributes;

  auto tmp = buildPath(tempDir(), "jstart-bspatch-dispatch-" ~ to!string(thisProcessID));
  rmTree(tmp);
  mkdirRecurse(tmp);
  scope (exit) {
    environment.remove("JSTART_BSPATCH");
    rmTree(tmp);
  }
  auto oldFile = buildPath(tmp, "old");
  auto patchFile = buildPath(tmp, "patch");
  write(oldFile, cast(ubyte[]) "abcdefghij");
  write(patchFile, craftPatch());

  // 模拟系统 bspatch：<old> <new> <patch>
  auto fake = buildPath(tmp, "fake-bspatch");
  write(fake, cast(ubyte[]) "#!/bin/sh\nprintf 'abcdeXYZfg' > \"$2\"\n");
  assert(execute(["chmod", "+x", fake]).status == 0);

  environment["JSTART_BSPATCH"] = "builtin";
  assert(systemBspatchPath() == "");
  assert(bspatchAvailable());

  environment["JSTART_BSPATCH"] = fake;
  assert(systemBspatchPath() == fake);

  auto sysOut = buildPath(tmp, "out");
  assert(applyBsdiff(oldFile, patchFile, sysOut, false));
  assert(cast(string) read(sysOut) == "abcdeXYZfg");

  // 系统命令产物尺寸与 patch 头部不符：判失败并回退内置实现
  auto fakeBad = buildPath(tmp, "fake-bspatch-bad");
  write(fakeBad, cast(ubyte[]) "#!/bin/sh\nprintf 'short' > \"$2\"\n");
  assert(execute(["chmod", "+x", fakeBad]).status == 0);
  environment["JSTART_BSPATCH"] = fakeBad;
  auto badOut = buildPath(tmp, "bad-out");
  assert(applyBsdiff(oldFile, patchFile, badOut, false));
  assert(cast(string) read(badOut) == "abcdeXYZfg");

  // 系统命令不存在时同样回退内置实现
  environment["JSTART_BSPATCH"] = buildPath(tmp, "no-such-bspatch");
  auto missingOut = buildPath(tmp, "missing-out");
  assert(applyBsdiff(oldFile, patchFile, missingOut, false));
  assert(cast(string) read(missingOut) == "abcdeXYZfg");

  // 强制内置实现：算法自己跑，bzip2 走宿主命令
  environment["JSTART_BSPATCH"] = "builtin";
  auto builtinOut = buildPath(tmp, "builtin-out");
  assert(applyBsdiff(oldFile, patchFile, builtinOut, false));
  assert(cast(string) read(builtinOut) == "abcdeXYZfg");
}

/**
 * jar/war 与 tar.gz 共用同一套 diff 逻辑，差别只在"应用 diff"的方式：构件本身
 * 就是可比对的文件，直接 bspatch，无需解压/重压（tar.gz 则要 gunzip -> bspatch -> gzip）。
 */
unittest {
  auto tmp = buildPath(tempDir(), "jstart-fetch-plain-" ~ to!string(thisProcessID));
  rmTree(tmp);
  auto remote = buildPath(tmp, "remote");
  auto versionDir = buildPath(remote, "org/example/demo/2.0");
  auto localBase = buildPath(tmp, "repository");
  auto snapBase = buildPath(tmp, "snapshots");
  mkdirRecurse(versionDir);
  mkdirRecurse(buildPath(localBase, "org/example/demo/1.0"));
  mkdirRecurse(snapBase);
  scope (exit) rmTree(tmp);

  // war：本地基线是 1.0 的 war，远端发布 1.0_2.0 的 war 补丁
  write(buildPath(localBase, "org/example/demo/1.0/demo-1.0.war"), cast(ubyte[]) "abcdefghij");
  write(buildPath(versionDir, "demo-2.0.war"), cast(ubyte[]) "abcdeXYZfg");
  write(buildPath(versionDir, "demo-2.0.war.sha1"),
      sha1OfFile(buildPath(versionDir, "demo-2.0.war")));
  write(buildPath(versionDir, "demo-1.0_2.0.war.diff"), craftPatch());

  auto server = new StaticServer(remote);
  server.start();
  scope (exit) server.stop();
  auto base = "http://127.0.0.1:" ~ to!string(server.port);

  auto r = fetchDist("org.example:demo:war:2.0", "1.0", base, localBase, false, snapBase);
  assert(r.ok && r.viaDelta);
  assert(r.path == buildPath(localBase, "org/example/demo/2.0/demo-2.0.war"));
  assert(cast(string) read(r.path) == "abcdeXYZfg");

  // 基线按打包类型取：本地只有 jar 基线时，war 目标找不到 1.0 war -> 整包下载（不报错）
  rmTree(buildPath(localBase, "org/example/demo/2.0"));
  remove(buildPath(localBase, "org/example/demo/1.0/demo-1.0.war"));
  write(buildPath(localBase, "org/example/demo/1.0/demo-1.0.jar"), cast(ubyte[]) "abcdefghij");
  auto r2 = fetchDist("org.example:demo:war:2.0", "1.0", base, localBase, false, snapBase);
  assert(r2.ok && !r2.viaDelta);
  assert(cast(string) read(r2.path) == "abcdeXYZfg");
}
