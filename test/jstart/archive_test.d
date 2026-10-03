/**
 * Unit tests for jstart.archive: gav 3/4/5 段解析、classifier/打包类型识别、Maven2 布局与依赖行解析。
 *
 * Test code lives outside of source/, mirroring the beangle micdn
 * layout. It is only compiled by the dub "unittest" configuration,
 * so released binaries never carry test code.
 */
module test.jstart.archive_test;

import jstart.archive : Archive, Artifact, LocalFile, RemoteFile, mergeLibraries, parseArchive,
  parseGav;

unittest {
  import std.exception : assertThrown;

  // 3-part gav
  auto a = parseGav("org.slf4j:slf4j-api:2.0.17", "org.slf4j:slf4j-api:2.0.17");
  assert(a.groupId == "org.slf4j");
  assert(a.artifactId == "slf4j-api");
  assert(a.ver == "2.0.17");
  assert(a.packaging == "jar");
  assert(a.classifier.length == 0);
  assert(a.layoutPath == "/org/slf4j/slf4j-api/2.0.17/slf4j-api-2.0.17.jar");

  // 4-part with packaging
  auto war = parseGav("g:a:war:1.0", "g:a:war:1.0");
  assert(war.packaging == "war");
  assert(war.ver == "1.0");

  // 4-part with classifier
  auto jl = parseGav("net.sf.json-lib:json-lib:jdk15:2.4", "net.sf.json-lib:json-lib:jdk15:2.4");
  assert(jl.classifier == "jdk15");
  assert(jl.packaging == "jar");
  assert(jl.layoutPath == "/net/sf/json-lib/json-lib/2.4/json-lib-2.4-jdk15.jar");

  // 4-part with tar.gz packaging
  auto tgz = parseGav("g:a:tar.gz:1.0", "g:a:tar.gz:1.0");
  assert(tgz.packaging == "tar.gz");

  // 5-part gav
  auto c = parseGav("g:a:jar:jdk15:2.4", "g:a:jar:jdk15:2.4");
  assert(c.classifier == "jdk15");
  assert(c.packaging == "jar");

  // sha1 companion
  assert(c.sha1.layoutPath == "/g/a/2.4/a-2.4-jdk15.jar.sha1");

  assertThrown!Exception(parseGav("", "g:a"));
  assertThrown!Exception(parseGav("", "a:b:c:d:e:f"));

  // line parsing
  auto gavLine = parseArchive("org.slf4j:slf4j-api:2.0.17");
  assert(cast(Artifact) gavLine !is null);

  auto gavUrl = parseArchive("gav://org.slf4j:slf4j-api:2.0.17");
  assert(cast(Artifact) gavUrl !is null);
  assert(gavUrl.raw == "gav://org.slf4j:slf4j-api:2.0.17");

  auto http = parseArchive("https://host.example/x.jar");
  assert(cast(RemoteFile) http !is null);

  auto local = parseArchive("lib/x.jar");
  assert(cast(LocalFile) local !is null);
  assert((cast(LocalFile) local).file == "lib/x.jar");

  auto fileUrl = parseArchive("file:///opt/lib/x.jar");
  assert((cast(LocalFile) fileUrl).file == "/opt/lib/x.jar");

  assert(parseArchive("   ") is null);
}

unittest {
  // mergeLibraries：libs 在前并覆盖同名 g:a（忽略版本），基础清单其余项按序追加。
  Archive[] libs = [cast(Archive) parseGav("org.slf4j:slf4j-api:2.0.99",
      "org.slf4j:slf4j-api:2.0.99")];
  Archive[] base = [
    cast(Archive) parseGav("org.slf4j:slf4j-api:2.0.17", "org.slf4j:slf4j-api:2.0.17"),
    cast(Archive) parseGav("com.zaxxer:HikariCP:7.0.3", "com.zaxxer:HikariCP:7.0.3"),
  ];
  auto merged = mergeLibraries(libs, base);
  assert(merged.length == 2);
  assert((cast(Artifact) merged[0]).ver == "2.0.99"); // libs 覆盖同名 g:a
  assert((cast(Artifact) merged[1]).artifactId == "HikariCP");

  // 非 gav（本地文件/远程 url）以原始行作键，同样可被 libs 覆盖。
  Archive[] libs2 = [cast(Archive) new RemoteFile("https://h/x.jar", "https://h/x.jar")];
  Archive[] base2 = [
    cast(Archive) new RemoteFile("https://h/x.jar", "https://h/x.jar"),
    cast(Archive) new LocalFile("lib/y.jar", "lib/y.jar"),
  ];
  auto merged2 = mergeLibraries(libs2, base2);
  assert(merged2.length == 2);

  // 空 libs 时保持基础清单原样。
  assert(mergeLibraries(null, base).length == 2);
}
