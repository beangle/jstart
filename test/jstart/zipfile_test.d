/**
 * Unit tests for jstart.zipfile: jar/war 条目读取与 Manifest Main-Class 解析。
 *
 * Test code lives outside of source/, mirroring the beangle micdn
 * layout. It is only compiled by the dub "unittest" configuration,
 * so released binaries never carry test code.
 */
module test.jstart.zipfile_test;

import jstart.zipfile : manifestMainClass, readZipEntry;
import std.zip : ZipArchive;

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
