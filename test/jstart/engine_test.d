/**
 * Unit tests for jstart.engine: --entry-out argv 解析与引擎依赖合并去重。
 * jstart 不内置任何引擎目录、也不解析引擎入口类（入口是 spec 的 [engine] init
 * 脚本），故不再测试别名/FQCN 选择。
 *
 * Test code lives outside of source/, mirroring the beangle micdn layout.
 */
module test.jstart.engine_test;

import std.conv : to;

import jstart.archive : Archive, Artifact, LocalFile, RemoteFile;
import jstart.engine : appendEngineDeps, engineDepsClasspathFile, entryArgvFile,
  entryClasspathFile, parseEntryArgv, subappsPlanFile;

unittest {
  // --entry-out：NUL 分隔 argv；忽略结尾 NUL 与手写换行；保留中间空参数。
  assert(parseEntryArgv("") == []);
  assert(parseEntryArgv("java\0-cp\0a:b\0Main\0") == ["java", "-cp", "a:b", "Main"]);
  assert(parseEntryArgv("java\0-cp\0Main\n") == ["java", "-cp", "Main"]);
  assert(parseEntryArgv("a\0\0b") == ["a", "", "b"], "empty middle arg kept");
  assert(parseEntryArgv("solo") == ["solo"]);
}

unittest {
  // 引擎依赖追加到应用依赖之后；g:a:v 重复不追加；顺序保持。
  auto slf4j = new Artifact("org.slf4j:slf4j-api:2.0.17", "org.slf4j", "slf4j-api",
      "2.0.17", "", "jar");
  auto local = new LocalFile("/opt/lib/x.jar", "/opt/lib/x.jar");
  auto engineCore = new Artifact("org.apache.tomcat.embed:tomcat-embed-core:11.0.21",
      "org.apache.tomcat.embed", "tomcat-embed-core", "11.0.21", "", "jar");
  auto engineSas = new Artifact("org.beangle.sas:beangle-sas-engine:0.13.17",
      "org.beangle.sas", "beangle-sas-engine", "0.13.17", "", "jar");
  auto remote = new RemoteFile("https://repo/x.jar", "https://repo/x.jar");

  auto merged = appendEngineDeps([cast(Archive) slf4j, local],
      [cast(Archive) engineCore, cast(Archive) slf4j, cast(Archive) engineSas, remote]);
  assert(merged.length == 5, merged.length.to!string);
  assert(cast(LocalFile) merged[1] !is null);
  assert(cast(Artifact) merged[2] is engineCore);
  assert(cast(Artifact) merged[3] is engineSas, "重复 slf4j 应被去重");
  assert(cast(RemoteFile) merged[4] !is null);
}

unittest {
  // base 下的约定文件名稳定：init 脚本按这些名字读写 plan/argv/classpath。
  assert(entryArgvFile == "engine-entry.argv");
  assert(entryClasspathFile == "engine-app.classpath");
  assert(engineDepsClasspathFile == "engine-deps.classpath");
  assert(subappsPlanFile == "engine-subapps.jstart");
}
