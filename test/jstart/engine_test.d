/**
 * Unit tests for jstart.engine: 引擎入口 main 解析（内置别名/FQCN/版本后缀）、
 * 内置默认依赖目录（tomcat/undertow）、[engine] 行占位符展开、--entry-out argv
 * 解析，以及引擎依赖合并去重。
 *
 * Test code lives outside of source/, mirroring the beangle micdn layout.
 */
module test.jstart.engine_test;

import std.algorithm : canFind;
import std.conv : to;

import jstart.archive : Archive, Artifact, LocalFile, RemoteFile;
import jstart.engine : appendEngineDeps, defaultDistEngineDeps, defaultEngineDeps,
  distTomcatEntryMain, engineEntryMain, expandEngineDeps, isEmbedEntryMain, parseEngineSel,
  parseEntryArgv, webappsPlanFile;

unittest {
  assert(engineEntryMain("tomcat") == "org.beangle.sas.engine.tomcat.EmbedCreator");
  assert(engineEntryMain("undertow") == "org.beangle.sas.engine.undertow.EmbedCreator");
  try {
    engineEntryMain("jetty");
    assert(false, "unknown engine should throw");
  } catch (Exception e) {
    assert(e.msg.canFind("tomcat") && e.msg.canFind("undertow"), e.msg);
  }
}

unittest {
  // engine 选择解析：别名 / 别名-版本 / FQCN。
  auto sel = parseEngineSel("tomcat");
  assert(sel.aliasName == "tomcat" && sel.ver.length == 0);
  assert(sel.entryMain == "org.beangle.sas.engine.tomcat.EmbedCreator");

  sel = parseEngineSel("tomcat-11.0.24");
  assert(sel.aliasName == "tomcat");
  assert(sel.ver == "11.0.24");
  assert(sel.entryMain == "org.beangle.sas.engine.tomcat.EmbedCreator");

  sel = parseEngineSel("undertow");
  assert(sel.aliasName == "undertow" && sel.ver.length == 0);
  assert(sel.entryMain == "org.beangle.sas.engine.undertow.EmbedCreator");

  // 含 "." 的值直接作为入口 main FQCN，别名/版本为空（无内置目录）。
  sel = parseEngineSel("org.beangle.sas.engine.tomcat.ServerCreator");
  assert(sel.entryMain == "org.beangle.sas.engine.tomcat.ServerCreator");
  assert(sel.aliasName.length == 0 && sel.ver.length == 0);
  sel = parseEngineSel("com.example.MyEngineMain");
  assert(sel.entryMain == "com.example.MyEngineMain" && sel.aliasName.length == 0);

  try {
    parseEngineSel("jetty");
    assert(false, "unknown engine should throw");
  } catch (Exception e) {
    assert(e.msg.canFind("tomcat") && e.msg.canFind("undertow"), e.msg);
  }
  try {
    parseEngineSel("undertow-2.4.3.Final");
    assert(false, "non-tomcat version suffix should throw");
  } catch (Exception e) {
    assert(e.msg.canFind("[engine]"), e.msg);
  }
}

unittest {
  // tomcat 内置默认依赖 = sas.sh tomcat 分支的三个 download 行。
  auto deps = defaultEngineDeps("tomcat");
  assert(deps.length == 3, "tomcat engine needs 3 explicit jars, got " ~ deps.length.to!string);
  string[string] expected;
  expected["org.beangle.sas:beangle-sas-engine"] = "0.13.17";
  expected["org.apache.tomcat.embed:tomcat-embed-core"] = "11.0.21";
  expected["org.apache.tomcat.embed:tomcat-embed-websocket"] = "11.0.21";
  foreach (d; deps) {
    auto a = cast(Artifact) d;
    assert(a !is null);
    auto key = a.groupId ~ ":" ~ a.artifactId;
    assert(key in expected, key);
    assert(a.ver == expected[key]);
    assert(a.packaging == "jar");
  }
  // undertow 内置目录 = sas.sh undertow 分支（sas 引擎 + undertow(EE10)/servlet/websocket
  // API/xnio/wildfly/smallrye）。
  auto udeps = defaultEngineDeps("undertow");
  assert(udeps.length == 22, "undertow catalog needs 22 jars, got " ~ udeps.length.to!string);
  string[string] expectedU;
  expectedU["org.beangle.sas:beangle-sas-engine"] = "0.13.17";
  expectedU["io.undertow:undertow-core"] = "2.4.4.Final";
  expectedU["io.undertow.ee:undertow-servlet"] = "2.0.2.Final";
  expectedU["io.undertow.ee:undertow-websockets"] = "2.0.2.Final";
  expectedU["org.jboss.logging:jboss-logging"] = "3.6.3.Final";
  expectedU["org.jboss.threads:jboss-threads"] = "3.9.2";
  expectedU["org.jboss.xnio:xnio-api"] = "3.8.16.Final";
  expectedU["org.jboss.xnio:xnio-nio"] = "3.8.16.Final";
  expectedU["jakarta.annotation:jakarta.annotation-api"] = "2.1.1";
  expectedU["jakarta.servlet:jakarta.servlet-api"] = "6.1.0";
  expectedU["jakarta.websocket:jakarta.websocket-api"] = "2.2.0";
  expectedU["jakarta.websocket:jakarta.websocket-client-api"] = "2.2.0";
  expectedU["org.wildfly.client:wildfly-client-config"] = "1.0.1.Final";
  expectedU["org.wildfly.common:wildfly-common"] = "2.0.1";
  expectedU["io.smallrye.common:smallrye-common-annotation"] = "2.14.0";
  expectedU["io.smallrye.common:smallrye-common-constraint"] = "2.14.0";
  expectedU["io.smallrye.common:smallrye-common-cpu"] = "2.14.0";
  expectedU["io.smallrye.common:smallrye-common-expression"] = "2.14.0";
  expectedU["io.smallrye.common:smallrye-common-function"] = "2.14.0";
  expectedU["io.smallrye.common:smallrye-common-net"] = "2.14.0";
  expectedU["io.smallrye.common:smallrye-common-os"] = "2.14.0";
  expectedU["io.smallrye.common:smallrye-common-ref"] = "2.14.0";
  auto seen = expectedU.length;
  foreach (d; udeps) {
    auto a = cast(Artifact) d;
    assert(a !is null);
    auto key = a.groupId ~ ":" ~ a.artifactId;
    assert(key in expectedU, "unexpected " ~ key);
    assert(a.ver == expectedU[key]);
    seen--;
  }
  assert(seen == 0, "some expected jars are missing");

  // 未知引擎没有内置默认目录。
  try {
    defaultEngineDeps("jetty");
    assert(false, "unknown engine has no built-in catalog");
  } catch (Exception e) {
    assert(e.msg.canFind("[engine]"), e.msg);
  }
}

unittest {
  // engine = tomcat-11.0.24：内置目录里两个 tomcat-embed jar 用指定版本，
  // beangle-sas-engine 保持内置默认版本。
  auto deps = defaultEngineDeps("tomcat", "11.0.24");
  assert(deps.length == 3);
  string[string] expected;
  expected["org.beangle.sas:beangle-sas-engine"] = "0.13.17";
  expected["org.apache.tomcat.embed:tomcat-embed-core"] = "11.0.24";
  expected["org.apache.tomcat.embed:tomcat-embed-websocket"] = "11.0.24";
  foreach (d; deps) {
    auto a = cast(Artifact) d;
    assert(a !is null);
    auto key = a.groupId ~ ":" ~ a.artifactId;
    assert(key in expected);
    assert(a.ver == expected[key]);
  }
}

unittest {
  // [engine] 行占位符：{tomcat.version} / {sas.version}，无占位符行原样返回。
  assert(expandEngineDeps("org.apache.tomcat.embed:tomcat-embed-core:{tomcat.version}")
      == "org.apache.tomcat.embed:tomcat-embed-core:11.0.21");
  assert(expandEngineDeps("org.apache.tomcat.embed:tomcat-embed-core:{tomcat.version}",
      "11.0.24") == "org.apache.tomcat.embed:tomcat-embed-core:11.0.24");
  assert(expandEngineDeps("org.apache.tomcat.embed:tomcat-embed-websocket:{tomcat.version}",
      "11.0.24") == "org.apache.tomcat.embed:tomcat-embed-websocket:11.0.24");
  assert(expandEngineDeps("org.beangle.sas:beangle-sas-engine:{sas.version}")
      == "org.beangle.sas:beangle-sas-engine:0.13.17");
  assert(expandEngineDeps("/opt/tomcat-embed-core-11.0.21.jar")
      == "/opt/tomcat-embed-core-11.0.21.jar");
}

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
  // Dist（多 webapp）模式：ServerCreator 是缺省入口 main，内嵌 *EmbedCreator 可识别。
  assert(distTomcatEntryMain == "org.beangle.sas.engine.tomcat.ServerCreator");
  assert(isEmbedEntryMain("org.beangle.sas.engine.tomcat.EmbedCreator"));
  assert(isEmbedEntryMain("org.beangle.sas.engine.undertow.EmbedCreator"));
  assert(!isEmbedEntryMain(distTomcatEntryMain));
  assert(!isEmbedEntryMain("com.example.MyEngine"));
  assert(webappsPlanFile == "engine-webapps.tsv");
}

unittest {
  // ServerCreator 内置目录 = beangle-sas-engine + tomcat 发行包 zip（容器来自发行包，
  // 不需要 embed jar）；版本后缀重钉 zip 版本。
  auto deps = defaultDistEngineDeps();
  assert(deps.length == 2, deps.length.to!string);
  auto sas = cast(Artifact) deps[0];
  auto zip = cast(Artifact) deps[1];
  assert(sas !is null && zip !is null);
  assert(sas.groupId == "org.beangle.sas" && sas.artifactId == "beangle-sas-engine");
  assert(sas.packaging == "jar");
  assert(zip.groupId == "org.apache.tomcat" && zip.artifactId == "tomcat");
  assert(zip.packaging == "zip");
  assert(zip.ver == "11.0.21");

  auto pinned = defaultDistEngineDeps("11.0.24");
  assert((cast(Artifact) pinned[1]).ver == "11.0.24");
}
