/**
 * Unit tests for jstart.zipfile: jar/war 条目读取与 Manifest Main-Class 解析。
 *
 * Test code lives outside of source/, mirroring the beangle micdn
 * layout. It is only compiled by the dub "unittest" configuration,
 * so released binaries never carry test code.
 */
module test.jstart.zipfile_test;

import jstart.zipfile : explodeZip, manifestMainClass, readZipEntry;
import std.zip : ArchiveMember, CompressionMethod, ZipArchive;

unittest {
  import std.file : exists, remove, write;
  import std.zip : ArchiveMember, CompressionMethod;

  auto zipPath = "/tmp/jstart_zipfile_test.zip";
  if (exists(zipPath)) {
    remove(zipPath);
  }
  {
    auto zip = new ZipArchive();
    auto member = new ArchiveMember();
    member.name = "META-INF/MANIFEST.MF";
    member.compressionMethod = CompressionMethod.deflate;
    member.expandedData = cast(
        ubyte[]) "Manifest-Version: 1.0\r\nMain-Class: org.example.Main\r\n".dup;
    zip.addMember(member);
    auto data = new ArchiveMember();
    data.name = "META-INF/beangle/dependencies";
    data.expandedData = cast(ubyte[]) "org.slf4j:slf4j-api:2.0.17\n".dup;
    zip.addMember(data);
    write(zipPath, zip.build());
  }
  auto content = readZipEntry(zipPath, "/META-INF/beangle/dependencies");
  assert(content !is null);
  assert(cast(string) content.idup == "org.slf4j:slf4j-api:2.0.17\n");
  assert(readZipEntry(zipPath, "META-INF/nope") is null);
  assert(manifestMainClass(zipPath) == "org.example.Main");
  remove(zipPath);
}

unittest {
  // explodeZip：嵌套目录/文件解压、目录条目建目录、路径穿越与绝对路径条目被跳过。
  import std.conv : to;
  import std.file : dirEntries, exists, isDir, mkdirRecurse, read, remove, tempDir, write,
    SpanMode;
  import std.path : buildPath;
  import std.process : thisProcessID;

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

  auto tmpBase = buildPath(tempDir(), "jstart-explode-test-" ~ to!string(thisProcessID));
  rmTree(tmpBase);
  mkdirRecurse(tmpBase);
  scope (exit) rmTree(tmpBase);

  auto zipPath = buildPath(tmpBase, "app.war");
  auto dest = buildPath(tmpBase, "exploded");
  {
    auto zip = new ZipArchive();
    void add(string name, string content) {
      auto m = new ArchiveMember();
      m.name = name;
      m.compressionMethod = CompressionMethod.deflate;
      m.expandedData = cast(ubyte[]) content.dup;
      zip.addMember(m);
    }
    add("WEB-INF/web.xml", "<web-app/>");
    add("WEB-INF/classes/org/example/App.class", "\0\x01\x02binary");
    add("assets/logo.txt", "logo");
    auto dirMember = new ArchiveMember();
    dirMember.name = "WEB-INF/lib/";
    dirMember.expandedData = cast(ubyte[]) "".dup;
    zip.addMember(dirMember);
    // 恶意条目：路径穿越/绝对路径/含 .. 段应被跳过
    add("../evil.txt", "evil");
    add("/abs.txt", "abs");
    add("a/../b.txt", "b");
    write(zipPath, zip.build());
  }
  auto count = explodeZip(zipPath, dest);
  assert(count == 3, "3 个合法文件被解压, 实际 " ~ count.to!string);
  assert(exists(buildPath(dest, "WEB-INF/web.xml")));
  assert(read(buildPath(dest, "WEB-INF/classes/org/example/App.class")) ==
      cast(ubyte[]) "\0\x01\x02binary");
  assert(read(buildPath(dest, "assets/logo.txt")) == cast(ubyte[]) "logo");
  assert(!exists(buildPath(dest, "evil.txt")));
  assert(!exists(buildPath(dest, "abs.txt")));
  assert(!exists(buildPath(dest, "a")));
  remove(zipPath);
}
