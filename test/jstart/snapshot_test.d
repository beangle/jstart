/**
 * Unit tests for jstart.snapshot（文件名/元数据解析）与 jstart.resolver 的 SNAPSHOT
 * 远端解析：micdn 的 `latest` 响应头、`maven-metadata.xml` 回退、以及令牌只加在 GET 上
 * （HEAD 保持匿名）。本地 127.0.0.1 起一个最小 HTTP 服务，不依赖外网。
 */
module test.jstart.snapshot_test;

import core.thread : Thread;
import core.time : msecs;
import std.array : join, split;
import std.conv : to;
import std.file : exists, isDir, mkdirRecurse, read, remove, tempDir, write, SpanMode,
  dirEntries;
import std.path : buildPath;
import std.process : environment, thisProcessID;
import std.socket : AddressFamily, InternetAddress, Socket, SocketType;
import std.string : indexOf, startsWith, strip, toLower;

import jstart.archive : RemoteFile, parseGav;
import jstart.distrepo : fetchDist;
import jstart.repo : LocalRepo, RemoteRepo, sha1OfFile;
import jstart.resolver : Resolver;
import jstart.snapshot : SnapshotFile, newestSnapshotValue, parseSnapshotName;
import jstart.spec : parseLaunchSpec;

/// 静态文件服务：HEAD 只回响应头，GET 回文件体；可按路径附加 HEAD 响应头（模拟 `latest`）。
private final class SnapshotServer {
  Socket listener;
  ushort port;
  string root;
  /// 路径 -> HEAD 附加响应头（含结尾 CRLF）
  string[string] headExtra;
  /// 最近一次 GET 携带的 Authorization 头
  string lastGetAuth;
  /// 最近一次 HEAD 携带的 Authorization 头
  string lastHeadAuth;
  /// 收到的 "METHOD /path" 列表
  string[] requests;
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
    listener.blocking = false; // 轮询式 accept，保证 stop() 可随时退出
    while (!stopped) {
      Socket s;
      try {
        s = listener.accept();
      } catch (Exception e) {
        if (!stopped) {
          Thread.sleep(5.msecs);
        }
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
    auto lines = head.split("\r\n");
    auto parts = lines[0].split(" ");
    if (parts.length < 2) {
      return;
    }
    auto method = parts[0];
    auto path = parts[1];
    auto q = path.indexOf("?");
    if (q >= 0) {
      path = path[0 .. q];
    }
    string auth;
    foreach (line; lines[1 .. $]) {
      if (line.toLower.startsWith("authorization:")) {
        auth = line["Authorization:".length .. $].strip;
      }
    }
    requests ~= method ~ " " ~ path;
    if (method == "HEAD") {
      lastHeadAuth = auth;
    } else {
      lastGetAuth = auth;
    }
    auto file = root ~ path;
    // 别名路径磁盘上没有对应文件，由 headExtra 模拟 micdn 的 latest 解析：回 200 + 附加头
    auto isAlias = (path in headExtra) !is null;
    if (!exists(file) || isDir(file)) {
      if (isAlias) {
        auto aliasHeader = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n" ~ headExtra[path]
          ~ "Connection: close\r\n\r\n";
        sendAll(s, cast(ubyte[]) aliasHeader, null);
        return;
      }
      sendAll(s, cast(ubyte[]) "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
          null);
      return;
    }
    const(ubyte)[] body = cast(const(ubyte)[]) read(file);
    string header = "HTTP/1.1 200 OK\r\nContent-Length: " ~ to!string(body.length) ~ "\r\n";
    if (method == "HEAD") {
      header ~= headExtra.get(path, "");
    }
    header ~= "Connection: close\r\n\r\n";
    sendAll(s, cast(ubyte[]) header, method == "GET" ? body : null);
  }

  private static void sendAll(Socket s, ubyte[] data, const(ubyte)[] payload) {
    auto off = 0;
    while (off < data.length) {
      auto n = s.send(data[off .. $]);
      if (n <= 0) {
        return;
      }
      off += n;
    }
    if (payload is null) {
      return;
    }
    off = 0;
    while (off < payload.length) {
      auto n = s.send(payload[off .. $]);
      if (n <= 0) {
        return;
      }
      off += n;
    }
  }
}

/// Recursively remove a temp tree.
private void rmTree(string path) {
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

unittest {
  // 文件名解析：时间戳、构建号、classifier、多点后缀。
  SnapshotFile f;
  assert(parseSnapshotName("demo-1.0-20260101.010101-2.jar", "demo", "1.0", "jar", f));
  assert(f.timestamp == "20260101.010101" && f.build == 2 && f.classifier == "");
  assert(parseSnapshotName("demo-1.0-20260101.010101-2-sources.jar", "demo", "1.0", "jar", f));
  assert(f.classifier == "sources");
  assert(parseSnapshotName("app-2.0-20260103.030303-4-linux-amd64.tar.gz", "app", "2.0",
      "tar.gz", f));
  assert(f.classifier == "linux-amd64" && f.packaging == "tar.gz");
  // 形状不符：无时间戳 / 打包后缀不匹配 / 无构建号
  assert(!parseSnapshotName("demo-1.0.jar", "demo", "1.0", "jar", f));
  assert(!parseSnapshotName("demo-1.0-20260101.010101-2.war", "demo", "1.0", "jar", f));
  assert(!parseSnapshotName("demo-1.0-20260101.010101.jar", "demo", "1.0", "jar", f));
}

unittest {
  // 元数据解析：<snapshotVersions> 按 extension/classifier 过滤并取最新；退化用 <snapshot>。
  auto xml = `<metadata><versioning>
    <snapshot><timestamp>20260103.030303</timestamp><buildNumber>7</buildNumber></snapshot>
    <snapshotVersions>
      <snapshotVersion><extension>jar</extension><value>2.0-20260101.010101-1</value></snapshotVersion>
      <snapshotVersion><extension>jar</extension><classifier>sources</classifier><value>2.0-20260103.030303-7</value></snapshotVersion>
      <snapshotVersion><extension>jar</extension><value>2.0-20260102.020202-5</value></snapshotVersion>
      <snapshotVersion><extension>war</extension><value>2.0-20260103.030303-7</value></snapshotVersion>
    </snapshotVersions>
  </versioning></metadata>`;
  assert(newestSnapshotValue(xml, "2.0", "jar", "") == "2.0-20260102.020202-5");
  assert(newestSnapshotValue(xml, "2.0", "war", "") == "2.0-20260103.030303-7");
  assert(newestSnapshotValue(xml, "2.0", "jar", "sources") == "2.0-20260103.030303-7");
  // extension/classifier 都对不上时退回 <snapshot> 的 timestamp/build（元数据与打包无关）
  assert(newestSnapshotValue(xml, "2.0", "pom", "") == "2.0-20260103.030303-7");
  // 两条来源都没有时返回空串
  assert(newestSnapshotValue("<metadata></metadata>", "2.0", "jar", "") == "");
  // 老式元数据（只有 <snapshot>）：拼出 {baseVer}-{ts}-{build}
  assert(newestSnapshotValue("<versioning><snapshot><timestamp>20260101.010101</timestamp>"
      ~ "<buildNumber>3</buildNumber></snapshot></versioning>", "2.0", "jar", "")
      == "2.0-20260101.010101-3");
}

unittest {
  auto tmp = buildPath(tempDir(), "jstart-snapshot-remote-" ~ to!string(thisProcessID));
  rmTree(tmp);
  auto remote = buildPath(tmp, "remote");
  auto localBase = buildPath(tmp, "repository");
  scope (exit) rmTree(tmp);

  // 1) micdn 风格：别名 HEAD 回带 latest 头，指向时间戳文件
  auto demoDir = buildPath(remote, "org/example/demo/1.0-SNAPSHOT");
  mkdirRecurse(demoDir);
  write(buildPath(demoDir, "demo-1.0-20260101.010101-1.jar"), "old");
  write(buildPath(demoDir, "demo-1.0-20260101.010101-1.jar.sha1"),
      sha1OfFile(buildPath(demoDir, "demo-1.0-20260101.010101-1.jar")));
  write(buildPath(demoDir, "demo-1.0-20260102.020202-2.jar"), "new");
  write(buildPath(demoDir, "demo-1.0-20260102.020202-2.jar.sha1"),
      sha1OfFile(buildPath(demoDir, "demo-1.0-20260102.020202-2.jar")));

  // 2) 标准 maven 风格：无 latest 头，靠 maven-metadata.xml 解析
  auto metaDir = buildPath(remote, "org/example/meta/2.0-SNAPSHOT");
  mkdirRecurse(metaDir);
  write(buildPath(metaDir, "meta-2.0-20260103.030303-4.jar"), "meta-new");
  write(buildPath(metaDir, "meta-2.0-20260103.030303-4.jar.sha1"),
      sha1OfFile(buildPath(metaDir, "meta-2.0-20260103.030303-4.jar")));
  write(buildPath(metaDir, "meta-2.0-20260101.010101-1.jar"), "meta-old");
  write(buildPath(metaDir, "maven-metadata.xml"),
      "<metadata><versioning><snapshotVersions>"
      ~ "<snapshotVersion><extension>jar</extension><value>2.0-20260101.010101-1</value></snapshotVersion>"
      ~ "<snapshotVersion><extension>jar</extension><value>2.0-20260103.030303-4</value></snapshotVersion>"
      ~ "</snapshotVersions></versioning></metadata>");

  auto server = new SnapshotServer(remote);
  server.start();
  scope (exit) server.stop();
  auto base = "http://127.0.0.1:" ~ to!string(server.port);
  auto aliasPath = "/org/example/demo/1.0-SNAPSHOT/demo-1.0-SNAPSHOT.jar";
  server.headExtra[aliasPath] = "latest: demo-1.0-20260102.020202-2.jar\r\n";

  // GET 带令牌、HEAD 保持匿名
  auto hadToken = () {
    auto v = environment.get("micdn_token");
    return v.length ? v : "";
  }();
  environment["micdn_token"] = "secret-token";
  scope (exit) {
    if (hadToken.length) {
      environment["micdn_token"] = hadToken;
    } else {
      environment.remove("micdn_token");
    }
  }

  auto local = new LocalRepo(localBase);
  auto resolver = new Resolver(local, [RemoteRepo("test", base)], false);
  // SNAPSHOT 上游与普通上游分开：本用例显式给出（生产由 bas 的 <SnapshotRepo remote> 传）
  resolver.snapshotRemotes = [RemoteRepo("test", base)];

  auto demo = parseGav("org.example:demo:1.0-SNAPSHOT", "org.example:demo:1.0-SNAPSHOT");
  auto expected = buildPath(localBase, "org/example/demo/1.0-SNAPSHOT",
      "demo-1.0-20260102.020202-2.jar");

  // 依赖解析路径（classpath 取时间戳文件）与下载：latest 头 → 时间戳文件
  auto missing = resolver.ensureDependencies([demo], 1);
  assert(missing.length == 0, missing.length ? missing[0] : "");
  auto ts = resolver.dependencyPath(demo);
  assert(ts == expected, ts);
  assert(cast(string) read(ts) == "new");
  assert(server.lastHeadAuth.length == 0, "HEAD 应保持匿名");
  assert(server.lastGetAuth == "Bearer secret-token",
      "GET 应带令牌: " ~ server.lastGetAuth);

  // 同一时间戳已在本地：再次解析（仍会 HEAD）但不再下载
  auto downloadsBefore = server.requests.length;
  string ts2;
  assert(resolver.ensureArtifact(demo, ts2));
  assert(ts2 == ts);
  assert(server.requests.length == downloadsBefore + 1,
      "已是最新时间戳时应只有一次 HEAD，不再下载");

  // 标准 maven：maven-metadata.xml 挑最新时间戳
  auto meta = parseGav("org.example:meta:2.0-SNAPSHOT", "org.example:meta:2.0-SNAPSHOT");
  assert(resolver.ensureArtifact(meta, ts), "maven-metadata 应解析出时间戳文件");
  assert(ts == buildPath(localBase, "org/example/meta/2.0-SNAPSHOT",
      "meta-2.0-20260103.030303-4.jar"), ts);
  assert(cast(string) read(ts) == "meta-new");

  // fetch/发行包侧不做快照元数据解析：-SNAPSHOT 只当字面版本名，直接下别名文件，
  // 不理会 latest 头（与 resolve 的 maven 解析不同）
  rmTree(buildPath(localBase, "org/example/demo"));
  write(buildPath(demoDir, "demo-1.0-SNAPSHOT.jar"), "literal");
  write(buildPath(demoDir, "demo-1.0-SNAPSHOT.jar.sha1"),
      sha1OfFile(buildPath(demoDir, "demo-1.0-SNAPSHOT.jar")));
  auto literal = buildPath(localBase, "org/example/demo/1.0-SNAPSHOT/demo-1.0-SNAPSHOT.jar");
  auto fr = fetchDist("org.example:demo:1.0-SNAPSHOT", "", base, localBase, false);
  assert(fr.ok && !fr.reused && !fr.viaDelta, "fetch 应整包下载字面别名");
  assert(fr.path == literal, fr.path);
  assert(cast(string) read(fr.path) == "literal");
  auto fr2 = fetchDist("org.example:demo:1.0-SNAPSHOT", "", base, localBase, false);
  assert(fr2.ok && fr2.reused && fr2.path == literal, "再取应复用本地字面文件");
}

unittest {
  // launch spec [libs] 里的 SNAPSHOT 走与内置依赖清单同一条快照解析：每次解析都问上游，
  // 上游发布新构建后，同一个 [libs] 应换到新的时间戳文件（而不是停在本地旧构建）。
  auto tmp = buildPath(tempDir(), "jstart-snapshot-speclibs-" ~ to!string(thisProcessID));
  rmTree(tmp);
  auto remote = buildPath(tmp, "remote");
  auto localBase = buildPath(tmp, "repository");
  auto dir = buildPath(remote, "org/example/demo/1.0-SNAPSHOT");
  mkdirRecurse(dir);
  write(buildPath(dir, "demo-1.0-20260101.010101-1.jar"), "one");
  write(buildPath(dir, "demo-1.0-20260101.010101-1.jar.sha1"),
      sha1OfFile(buildPath(dir, "demo-1.0-20260101.010101-1.jar")));
  scope (exit) rmTree(tmp);

  auto server = new SnapshotServer(remote);
  server.start();
  scope (exit) server.stop();
  auto base = "http://127.0.0.1:" ~ to!string(server.port);
  auto aliasPath = "/org/example/demo/1.0-SNAPSHOT/demo-1.0-SNAPSHOT.jar";
  server.headExtra[aliasPath] = "latest: demo-1.0-20260101.010101-1.jar\r\n";

  string[] warnings;
  auto spec = parseLaunchSpec("[app]\nentry = app.jar\n\n[libs]\n"
      ~ "org.example:demo:1.0-SNAPSHOT\n", warnings);
  assert(spec.libs.length == 1);

  auto local = new LocalRepo(localBase);
  auto resolver = new Resolver(local, [], false);
  resolver.snapshotRemotes = [RemoteRepo("test", base)];
  auto deps = resolver.parseDependencyText(spec.libs.join("\n"));
  assert(deps.length == 1);

  auto first = buildPath(localBase, "org/example/demo/1.0-SNAPSHOT",
      "demo-1.0-20260101.010101-1.jar");
  auto missing = resolver.ensureDependencies(deps, 1);
  assert(missing.length == 0, missing.length ? missing[0] : "");
  assert(resolver.dependencyPath(deps[0]) == first, resolver.dependencyPath(deps[0]));

  // 上游发布 build 2：同一个 [libs] 再次解析应换到新时间戳文件
  write(buildPath(dir, "demo-1.0-20260102.020202-2.jar"), "two");
  write(buildPath(dir, "demo-1.0-20260102.020202-2.jar.sha1"),
      sha1OfFile(buildPath(dir, "demo-1.0-20260102.020202-2.jar")));
  server.headExtra[aliasPath] = "latest: demo-1.0-20260102.020202-2.jar\r\n";
  missing = resolver.ensureDependencies(deps, 1);
  assert(missing.length == 0, missing.length ? missing[0] : "");
  auto second = buildPath(localBase, "org/example/demo/1.0-SNAPSHOT",
      "demo-1.0-20260102.020202-2.jar");
  assert(resolver.dependencyPath(deps[0]) == second, resolver.dependencyPath(deps[0]));
}

unittest {
  // --offline：不做任何远程探测/下载，只用本地仓库
  auto tmp = buildPath(tempDir(), "jstart-offline-snap-" ~ to!string(thisProcessID));
  rmTree(tmp);
  auto remote = buildPath(tmp, "remote");
  auto localBase = buildPath(tmp, "repository");
  mkdirRecurse(buildPath(remote, "org/example/demo/1.0-SNAPSHOT"));
  scope (exit) rmTree(tmp);

  auto server = new SnapshotServer(remote);
  server.start();
  scope (exit) server.stop();
  auto base = "http://127.0.0.1:" ~ to!string(server.port);

  auto local = new LocalRepo(localBase);
  // 故意传入远端：offline 必须压过 --remote，一个请求都不发
  auto resolver = new Resolver(local, [RemoteRepo("test", base)], false, true, true);
  auto snap = parseGav("org.example:demo:1.0-SNAPSHOT", "org.example:demo:1.0-SNAPSHOT");

  auto missing = resolver.ensureDependencies([snap], 1);
  assert(missing.length == 1, "offline 且本地无件应报缺件");
  assert(server.requests.length == 0, "offline 不应发出任何请求");

  // 本地放入时间戳文件后命中，仍然没有请求
  auto dir = buildPath(localBase, "org/example/demo/1.0-SNAPSHOT");
  mkdirRecurse(dir);
  auto tsFile = buildPath(dir, "demo-1.0-20261003.120000-1.jar");
  write(tsFile, "local");
  missing = resolver.ensureDependencies([snap], 1);
  assert(missing.length == 0);
  assert(resolver.dependencyPath(snap) == tsFile, resolver.dependencyPath(snap));
  assert(server.requests.length == 0);

  // 远程文件依赖在 offline 下也不下载
  auto rf = new RemoteFile(base ~ "/x.jar", base ~ "/x.jar");
  missing = resolver.ensureDependencies([rf], 1);
  assert(missing.length == 1, "offline 下远程文件依赖应报缺件");
  assert(server.requests.length == 0);
}

unittest {
  // SNAPSHOT 只走显式快照上游：不兜到 --remote；没配上游时本地命中即可用，本地缺失才报错
  auto tmp = buildPath(tempDir(), "jstart-snapshot-remotes-" ~ to!string(thisProcessID));
  rmTree(tmp);
  auto remote = buildPath(tmp, "remote");
  auto localBase = buildPath(tmp, "repository");
  auto dir = buildPath(remote, "org/example/demo/1.0-SNAPSHOT");
  mkdirRecurse(dir);
  write(buildPath(dir, "demo-1.0-20261003.120000-1.jar"), "remote");
  scope (exit) rmTree(tmp);

  auto server = new SnapshotServer(remote);
  server.start();
  scope (exit) server.stop();
  auto base = "http://127.0.0.1:" ~ to!string(server.port);
  server.headExtra["/org/example/demo/1.0-SNAPSHOT/demo-1.0-SNAPSHOT.jar"]
    = "latest: demo-1.0-20261003.120000-1.jar\r\n";

  auto local = new LocalRepo(localBase);
  auto resolver = new Resolver(local, [RemoteRepo("test", base)], false, true);
  auto snap = parseGav("org.example:demo:1.0-SNAPSHOT", "org.example:demo:1.0-SNAPSHOT");

  // 只配了普通上游：本地没有快照文件、需要拉取却没有快照上游 → Missing，且一个请求都不发
  auto missing = resolver.ensureDependencies([snap], 1);
  assert(missing.length == 1, "未配置快照上游且本地缺失时应报 Missing");
  assert(server.requests.length == 0, "未配置快照上游时不应发出请求");

  // 本地放入快照文件后，即使没配快照上游也直接采用，不发请求也不报错
  auto snapDir = buildPath(localBase, "org/example/demo/1.0-SNAPSHOT");
  mkdirRecurse(snapDir);
  auto localSnap = buildPath(snapDir, "demo-1.0-20260101.010101-1.jar");
  write(localSnap, "local");
  missing = resolver.ensureDependencies([snap], 1);
  assert(missing.length == 0, "没配快照上游时本地已有快照应可用");
  assert(resolver.dependencyPath(snap) == localSnap);
  assert(server.requests.length == 0, "本地命中不应发出请求");

  // offline 语义相同：不拉取，本地命中即可用
  auto offlineResolver = new Resolver(local, [], false, true, true);
  missing = offlineResolver.ensureDependencies([snap], 1);
  assert(missing.length == 0, "offline 下本地快照命中应可用");
  assert(server.requests.length == 0, "offline 不应发出请求");

  // 显式给出快照上游后才解析、下载最新构建
  resolver.snapshotRemotes = [RemoteRepo("test", base)];
  missing = resolver.ensureDependencies([snap], 1);
  assert(missing.length == 0);
  assert(cast(string) read(resolver.dependencyPath(snap)) == "remote");
  assert(server.requests.length > 0, "配了快照上游应向上游解析最新构建");
}
