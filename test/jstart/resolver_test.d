/**
 * Unit tests for jstart.resolver: jar/war/解压目录/文本文件的依赖解析、去重、空行与无描述 jar。
 *
 * Test code lives outside of source/, mirroring the beangle micdn
 * layout. It is only compiled by the dub "unittest" configuration,
 * so released binaries never carry test code.
 */
module test.jstart.resolver_test;

import jstart.archive : Artifact, LocalFile, RemoteFile, parseGav;
import jstart.repo : LocalRepo;
import jstart.resolver : Resolver;

unittest {
  import std.conv : to;
  import std.file : dirEntries, exists, isDir, mkdirRecurse, remove, tempDir, write, SpanMode;
  import std.process : thisProcessID;
  import std.path : buildPath;
  import std.zip : ArchiveMember, CompressionMethod, ZipArchive;

  /// Recursively remove a temp tree.
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

  /// Write a zip containing the given text entries.
  void makeZip(string zipPath, string[string] entries) {
    auto zip = new ZipArchive();
    foreach (name, content; entries) {
      auto member = new ArchiveMember();
      member.name = name;
      member.compressionMethod = CompressionMethod.deflate;
      member.expandedData = cast(ubyte[]) content.dup;
      zip.addMember(member);
    }
    write(zipPath, zip.build());
  }

  auto tmpBase = buildPath(tempDir(), "jstart-resolver-test-" ~ to!string(thisProcessID));
  rmTree(tmpBase);
  mkdirRecurse(tmpBase);
  scope (exit)
    rmTree(tmpBase);

  auto local = new LocalRepo(buildPath(tmpBase, "repo"));
  // 空远程列表：解析过程不发起任何网络请求
  auto resolver = new Resolver(local, [], false);

  // ---- jar：META-INF/beangle/dependencies 逐行解析 ----
  enum depsContent = "org.slf4j:slf4j-api:2.0.17\n" ~ "ch.qos.logback:logback-classic:jar:1.5.20\n"
    ~ "net.sf.json-lib:json-lib:jdk15:2.4\n" ~ "gav://org.apache.commons:commons-lang3:3.18.0\n"
    ~ "/opt/local/lib/extra.jar\n" ~ "https://repo.example.com/static/lib-1.0.jar\n"
    ~ "\n" ~ "  \n" ~ "org.slf4j:slf4j-api:2.0.17\n"; // 重复行应被去重

  auto jarPath = buildPath(tmpBase, "app.jar");
  makeZip(jarPath, ["META-INF/beangle/dependencies": depsContent]);
  auto jarDeps = resolver.resolveDependencies(jarPath);
  assert(jarDeps.length == 6,
      "jar 内 6 条唯一依赖(空行/重复行被剔除), 实际 " ~ jarDeps.length.to!string);

  // 1. 普通 gav
  auto a0 = cast(Artifact) jarDeps[0];
  assert(a0 !is null);
  assert(a0.groupId == "org.slf4j");
  assert(a0.artifactId == "slf4j-api");
  assert(a0.ver == "2.0.17");
  assert(a0.packaging == "jar");
  assert(a0.classifier.length == 0);
  assert(a0.layoutPath == "/org/slf4j/slf4j-api/2.0.17/slf4j-api-2.0.17.jar");

  // 2. 4 段 gav，显式 packaging=jar
  auto a1 = cast(Artifact) jarDeps[1];
  assert(a1 !is null);
  assert(a1.groupId == "ch.qos.logback");
  assert(a1.artifactId == "logback-classic");
  assert(a1.ver == "1.5.20");
  assert(a1.packaging == "jar");
  assert(a1.classifier.length == 0);

  // 3. 4 段 gav，第三段 jdk15 被识别为 classifier
  auto a2 = cast(Artifact) jarDeps[2];
  assert(a2 !is null);
  assert(a2.classifier == "jdk15");
  assert(a2.packaging == "jar");
  assert(a2.ver == "2.4");
  assert(a2.layoutPath == "/net/sf/json-lib/json-lib/2.4/json-lib-2.4-jdk15.jar");

  // 4. gav:// 前缀
  auto a3 = cast(Artifact) jarDeps[3];
  assert(a3 !is null);
  assert(a3.groupId == "org.apache.commons");
  assert(a3.artifactId == "commons-lang3");
  assert(a3.ver == "3.18.0");
  assert(a3.packaging == "jar");

  // 5. 本地文件
  auto lf = cast(LocalFile) jarDeps[4];
  assert(lf !is null);
  assert(lf.file == "/opt/local/lib/extra.jar");

  // 6. 远程 url 文件
  auto rf = cast(RemoteFile) jarDeps[5];
  assert(rf !is null);
  assert(rf.url == "https://repo.example.com/static/lib-1.0.jar");

  // ---- war：WEB-INF/classes/META-INF/beangle/dependencies ----
  auto warPath = buildPath(tmpBase, "app.war");
  makeZip(warPath, [
    "WEB-INF/classes/META-INF/beangle/dependencies": "com.zaxxer:HikariCP:7.0.2\n"
  ]);
  auto warDeps = resolver.resolveDependencies(warPath);
  assert(warDeps.length == 1);
  auto warArt = cast(Artifact) warDeps[0];
  assert(warArt !is null);
  assert(warArt.artifactId == "HikariCP");
  assert(warArt.ver == "7.0.2");

  // ---- 解压后的 war 目录 ----
  auto dirPath = buildPath(tmpBase, "exploded");
  auto nestedDir = dirPath ~ "/WEB-INF/classes/META-INF/beangle";
  mkdirRecurse(nestedDir);
  write(buildPath(nestedDir, "dependencies"), "org.apache.commons:commons-lang3:3.18.0\n");
  auto dirDeps = resolver.resolveDependencies(dirPath);
  assert(dirDeps.length == 1);
  auto dirArt = cast(Artifact) dirDeps[0];
  assert(dirArt !is null && dirArt.artifactId == "commons-lang3");

  // ---- 普通文本文件不再是依赖清单（纯文本清单已不支持）：不读取，返回空 ----
  auto txtPath = buildPath(tmpBase, "deps.txt");
  write(txtPath, "org.slf4j:slf4j-api:2.0.17\n");
  assert(resolver.resolveDependencies(txtPath).length == 0);

  // ---- 无依赖文件的 jar：返回空列表而非报错 ----
  auto bareJar = buildPath(tmpBase, "bare.jar");
  makeZip(bareJar,
      [
        "META-INF/MANIFEST.MF": "Manifest-Version: 1.0\nMain-Class: org.example.Main\n"
  ]);
  assert(resolver.resolveDependencies(bareJar).length == 0);
  assert(resolver.mainClassOf(bareJar) == "org.example.Main");
}

unittest {
  import std.conv : to;
  import std.file : dirEntries, exists, isDir, mkdirRecurse, remove, tempDir, write, SpanMode;
  import std.path : buildPath;
  import std.process : thisProcessID;

  import jstart.repo : LocalRepo;

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

  // dependencyPath：release 走本地仓库布局；SNAPSHOT 命中本地快照库时间戳文件。
  auto tmpBase = buildPath(tempDir(), "jstart-deppath-test-" ~ to!string(thisProcessID));
  rmTree(tmpBase);
  mkdirRecurse(tmpBase);
  scope (exit) rmTree(tmpBase);

  auto local = new LocalRepo(tmpBase);
  auto resolver = new Resolver(local, [], false);

  // release 构件：本地缺件且无远程时不下载，dependencyPath 仍是仓库布局路径。
  auto rel = parseGav("org.test:demo:1.0", "org.test:demo:1.0");
  auto missing = resolver.ensureDependencies([rel], 1);
  assert(missing.length == 1, "release 缺件应报 Missing");
  assert(resolver.dependencyPath(rel) == local.filePath(rel));

  // SNAPSHOT：快照库中放时间戳文件后，dependencyPath 指向该时间戳文件。
  auto snap = parseGav("org.test:demo:1.0-SNAPSHOT", "org.test:demo:1.0-SNAPSHOT");
  auto dir = buildPath(tmpBase, "org/test/demo/1.0-SNAPSHOT");
  mkdirRecurse(dir);
  auto tsFile = buildPath(dir, "demo-1.0-20260101.010101-2.jar");
  write(tsFile, "snapshot-bytes");
  missing = resolver.ensureDependencies([snap], 1);
  assert(missing.length == 0, "本地时间戳命中不下载");
  assert(resolver.dependencyPath(snap) == tsFile,
      "classpath 应指向时间戳文件: " ~ resolver.dependencyPath(snap));
}
