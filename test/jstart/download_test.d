/**
 * Unit tests for parallel downloads: cross-dependency concurrency (--jobs)
 * and per-file Range segmented downloads. A tiny threaded HTTP server on
 * 127.0.0.1 is used so no external network is involved.
 *
 * Test code lives outside of source/, mirroring the beangle micdn
 * layout. It is only compiled by the dub "unittest" configuration,
 * so released binaries never carry test code.
 */
module test.jstart.download_test;

import core.thread : Thread;
import core.time : msecs;
import std.array : join, split;
import std.conv : to;
import std.format : format;
import std.socket : AddressFamily, InternetAddress, Socket, SocketType;
import std.string : indexOf, startsWith, strip, toLower;

import jstart.archive : Archive, RemoteFile;
import jstart.repo : LocalRepo;
import jstart.resolver : Resolver;

/// Minimal threaded HTTP server with optional Range support.
private final class TestServer {
  Socket listener;
  ushort port;
  bool rangeOk;
  ubyte[] payload;
  /// Max simultaneously active requests (all methods).
  int maxActive;
  /// Max simultaneously active GET requests (probes are HEAD, not counted).
  int maxActiveGets;
  /// Number of successful byte-range GET requests.
  int rangeGets;
  private Object lock_ = new Object();
  private int active;
  private int activeGets;
  private bool stopped;
  private Thread worker;

  this(bool withRange, ubyte[] data) {
    rangeOk = withRange;
    payload = data;
  }

  void start() {
    listener = new Socket(AddressFamily.INET, SocketType.STREAM);
    listener.bind(new InternetAddress("127.0.0.1", 0));
    listener.listen(32);
    auto ia = cast(InternetAddress) listener.localAddress;
    port = ia.port;
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
    listener.blocking = false; // 轮询式 accept，保证 stop() 可随时退出
    while (!stopped) {
      Socket s;
      try {
        s = listener.accept();
      } catch (Exception e) {
        Thread.sleep(5.msecs);
        continue;
      }
      spawnHandle(s);
    }
    try {
      listener.close();
    } catch (Exception e) {
    }
  }

  private void spawnHandle(Socket s) {
    auto t = new Thread(() => handle(s));
    t.start();
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
    auto headText = head[0 .. head.indexOf("\r\n\r\n") + 4];
    auto lines = headText.split("\r\n");
    if (lines.length < 1) {
      return;
    }
    auto parts = lines[0].split(" ");
    if (parts.length < 2) {
      return;
    }
    auto method = parts[0];
    auto isGet = method == "GET";
    string rangeHdr;
    foreach (line; lines[1 .. $]) {
      if (line.toLower.startsWith("range:")) {
        rangeHdr = line["Range:".length .. $].strip;
      }
    }

    synchronized (lock_) {
      active++;
      if (active > maxActive) {
        maxActive = active;
      }
      if (isGet) {
        activeGets++;
        if (activeGets > maxActiveGets) {
          maxActiveGets = activeGets;
        }
      }
    }
    scope (exit) synchronized (lock_) {
      active--;
      if (isGet) {
        activeGets--;
      }
    }
    Thread.sleep(200.msecs); // give concurrent requests a real overlap window

    auto start = 0L;
    auto end = cast(long) payload.length - 1;
    auto partial = false;
    if (rangeOk && rangeHdr.length) {
      // rangeHdr looks like "bytes=0-1048575"
      auto spec = rangeHdr;
      if (spec.toLower.startsWith("bytes=")) {
        spec = spec["bytes=".length .. $];
      }
      auto rp = spec.split("-");
      if (rp.length == 2) {
        try {
          start = to!long(rp[0]);
          end = to!long(rp[1]);
          partial = true;
          synchronized (lock_) {
            rangeGets++;
          }
        } catch (Exception e) {
        }
      }
    }
    if (partial) {
      if (start < 0 || end >= payload.length || start > end) {
        return; // malformed range: drop the connection
      }
    }
    auto body = payload[cast(size_t) start .. cast(size_t) end + 1];
    auto header = "HTTP/1.1 " ~ (partial ? "206 Partial Content" : "200 OK")
      ~ "\r\nContent-Length: " ~ to!string(body.length) ~ "\r\n";
    if (rangeOk) {
      header ~= "Accept-Ranges: bytes\r\n";
    }
    if (partial) {
      header ~= "Content-Range: bytes " ~ to!string(start) ~ "-" ~ to!string(end)
        ~ "/" ~ to!string(payload.length) ~ "\r\n";
    }
    header ~= "Connection: close\r\n\r\n";
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

/// Recursively remove a temp tree.
private void rmTree(string path) {
  import std.file : dirEntries, exists, isDir, remove, SpanMode;

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

/// Each GET is answered after a fixed delay, so overlapping GETs can be
/// observed through maxActiveGets.
unittest {
  import std.file : tempDir;
  import std.path : buildPath;
  import std.process : thisProcessID;

  // jobs=2：两个远程依赖并发下载，服务端观测到同时活跃的 GET >= 2。
  auto server = new TestServer(false, cast(ubyte[]) "payload".dup);
  server.start();
  scope (exit) server.stop();

  auto tmpBase = buildPath(tempDir(), "jstart-par-test-" ~ to!string(thisProcessID));
  rmTree(tmpBase);
  scope (exit) rmTree(tmpBase);
  auto local = new LocalRepo(tmpBase);
  auto resolver = new Resolver(local, [], false);
  Archive[] deps;
  foreach (i; 0 .. 2) {
    auto url = "http://127.0.0.1:" ~ to!string(server.port) ~ "/dep" ~ to!string(i) ~ ".jar";
    deps ~= new RemoteFile(url, url);
  }
  auto missing = resolver.ensureDependencies(deps, 2);
  assert(missing.length == 0, missing.join(","));
  assert(server.maxActiveGets >= 2,
      format("jobs=2 should overlap downloads, maxActiveGets=%d", server.maxActiveGets));
}

unittest {
  import std.file : tempDir;
  import std.path : buildPath;
  import std.process : thisProcessID;

  // jobs=1：严格串行，同一时刻最多 1 个活跃 GET。
  auto server = new TestServer(false, cast(ubyte[]) "payload".dup);
  server.start();
  scope (exit) server.stop();

  auto tmpBase = buildPath(tempDir(), "jstart-seq-test-" ~ to!string(thisProcessID));
  rmTree(tmpBase);
  scope (exit) rmTree(tmpBase);
  auto local = new LocalRepo(tmpBase);
  auto resolver = new Resolver(local, [], false);
  Archive[] deps;
  foreach (i; 0 .. 2) {
    auto url = "http://127.0.0.1:" ~ to!string(server.port) ~ "/dep" ~ to!string(i) ~ ".jar";
    deps ~= new RemoteFile(url, url);
  }
  auto missing = resolver.ensureDependencies(deps, 1);
  assert(missing.length == 0, missing.join(","));
  assert(server.maxActiveGets == 1,
      format("jobs=1 must stay serial, maxActiveGets=%d", server.maxActiveGets));
}

unittest {
  import std.file : read, tempDir;
  import std.path : buildPath;
  import std.process : thisProcessID;

  // Range 分段：>1MB 文件在支持 Range 的服务上被拆成多段并发下载并正确合并。
  enum size = 3 * 1024 * 1024 + 17;
  auto payload = new ubyte[size];
  foreach (i; 0 .. size) {
    payload[i] = cast(ubyte) (i % 251);
  }
  auto server = new TestServer(true, payload);
  server.start();
  scope (exit) server.stop();

  auto tmpBase = buildPath(tempDir(), "jstart-range-test-" ~ to!string(thisProcessID));
  rmTree(tmpBase);
  scope (exit) rmTree(tmpBase);
  auto local = new LocalRepo(tmpBase);
  auto resolver = new Resolver(local, [], false);
  auto url = "http://127.0.0.1:" ~ to!string(server.port) ~ "/big.jar";
  auto rf = new RemoteFile(url, url);
  auto missing = resolver.ensureDependencies([rf], 4);
  assert(missing.length == 0, missing.join(","));
  assert(server.rangeGets >= 2,
      format("expected segmented downloads, got %d range GETs", server.rangeGets));
  auto cached = resolver.remoteLocalPath(rf);
  assert(read(cached) == payload, "merged range download content mismatch");
}
