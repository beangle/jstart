/**
 * Unit tests for jstart.engine: war 引擎主类映射、tomcat 内置默认依赖、上下文路径
 * 布局推导、--path/--base 扫描与引擎依赖合并去重。
 *
 * Test code lives outside of source/, mirroring the beangle micdn layout.
 */
module test.jstart.engine_test;

import std.algorithm : canFind;
import std.conv : to;

import jstart.archive : Archive, Artifact, LocalFile, RemoteFile;
import jstart.engine : appendEngineDeps, defaultEngineDeps, defaultWarBase, engineMainClass,
  expandEngineDeps, normalizeContextPath, parseEngineSel, scanEngineArgs, warDocBaseDir,
  warDocBaseName;

unittest {
  assert(engineMainClass("tomcat") == "org.beangle.sas.engine.tomcat.Bootstrap");
  assert(engineMainClass("undertow") == "org.beangle.sas.engine.undertow.Bootstrap");
  try {
    engineMainClass("jetty");
    assert(false, "unknown engine should throw");
  } catch (Exception e) {
    assert(e.msg.canFind("tomcat") && e.msg.canFind("undertow"), e.msg);
  }
}

unittest {
  // tomcat 内置默认依赖 = sas.sh tomcat 分支的三个 download 行。
  auto deps = defaultEngineDeps("tomcat");
  assert(deps.length == 3, "tomcat engine needs 3 explicit jars, got " ~ deps.length.to!string);
  string[string] expected;
  expected["org.beangle.sas:beangle-sas-engine"] = "0.13.10";
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
  // undertow 内置目录 = sas.sh undertow 分支（sas 引擎 + undertow/xnio/wildfly/smallrye）。
  auto udeps = defaultEngineDeps("undertow");
  assert(udeps.length == 14, "undertow catalog needs 14 jars, got " ~ udeps.length.to!string);
  string[string] expectedU;
  expectedU["org.beangle.sas:beangle-sas-engine"] = "0.13.10";
  expectedU["io.undertow:undertow-core"] = "2.3.24.Final";
  expectedU["io.undertow:undertow-servlet"] = "2.3.24.Final";
  expectedU["org.jboss.logging:jboss-logging"] = "3.6.1.Final";
  expectedU["org.jboss.threads:jboss-threads"] = "3.7.0.Final";
  expectedU["org.jboss.xnio:xnio-api"] = "3.8.16.Final";
  expectedU["org.jboss.xnio:xnio-nio"] = "3.8.16.Final";
  expectedU["jakarta.annotation:jakarta.annotation-api"] = "2.1.1";
  expectedU["org.wildfly.client:wildfly-client-config"] = "1.0.1.Final";
  expectedU["org.wildfly.common:wildfly-common"] = "1.5.4.Final";
  expectedU["io.smallrye.common:smallrye-common-annotation"] = "2.6.0";
  expectedU["io.smallrye.common:smallrye-common-constraint"] = "2.6.0";
  expectedU["io.smallrye.common:smallrye-common-cpu"] = "2.6.0";
  expectedU["io.smallrye.common:smallrye-common-function"] = "2.6.0";
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
  // engine 选择解析：tomcat / tomcat-<版本> / undertow。
  auto sel = parseEngineSel("tomcat");
  assert(sel.name == "tomcat" && sel.ver.length == 0);
  sel = parseEngineSel("tomcat-11.0.24");
  assert(sel.name == "tomcat");
  assert(sel.ver == "11.0.24");
  sel = parseEngineSel("undertow");
  assert(sel.name == "undertow" && sel.ver.length == 0);
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
  // engine = tomcat-11.0.24：内置目录里两个 tomcat-embed jar 用指定版本，
  // beangle-sas-engine 保持内置默认版本。
  auto deps = defaultEngineDeps("tomcat", "11.0.24");
  assert(deps.length == 3);
  string[string] expected;
  expected["org.beangle.sas:beangle-sas-engine"] = "0.13.10";
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
      == "org.beangle.sas:beangle-sas-engine:0.13.10");
  assert(expandEngineDeps("/opt/tomcat-embed-core-11.0.21.jar")
      == "/opt/tomcat-embed-core-11.0.21.jar");
}

unittest {
  // 与 beangle/sas Server.Config.normalizePath 一致。
  assert(normalizeContextPath("") == "");
  assert(normalizeContextPath("/") == "");
  assert(normalizeContextPath("app") == "/app");
  assert(normalizeContextPath("/app") == "/app");
  assert(normalizeContextPath("/a/b/") == "/a/b");
  assert(normalizeContextPath("//a//b") == "/a/b");
}

unittest {
  // 爆炸目录名 = sas guessDocBase 布局：ROOT 或 /a/b -> a#b。
  assert(warDocBaseName("") == "ROOT");
  assert(warDocBaseName("/") == "ROOT");
  assert(warDocBaseName("/app") == "app");
  assert(warDocBaseName("app") == "app");
  assert(warDocBaseName("/a/b") == "a#b");
  assert(warDocBaseName("/a/b/") == "a#b");
  assert(warDocBaseName("/..") == "", "unsafe name must be rejected");
  assert(warDocBaseName("/.") == "", "unsafe name must be rejected");
  assert(warDocBaseDir("/tmp/sas", "ROOT") == "/tmp/sas/webapps/ROOT");
  assert(warDocBaseDir("/tmp/sas", "a#b") == "/tmp/sas/webapps/a#b");
}

unittest {
  // --path/--base 扫描：最后一次出现生效；--port 等不读取。
  string path, base;
  scanEngineArgs(["--port=8080", "--path=/base1"], path, base);
  assert(path == "/base1");
  assert(base.length == 0);
  scanEngineArgs(["--path=/a", "--path=/b", "--base=/sas"], path, base);
  assert(path == "/b", "last --path wins");
  assert(base == "/sas");
  scanEngineArgs(["--path=/x"], path, base);
  assert(path == "/x");
  assert(base == "/sas", "scan only overwrites given args");
}

unittest {
  assert(defaultWarBase().canFind("jstart-sas"), defaultWarBase());
}

unittest {
  // 引擎依赖追加到应用依赖之后；g:a:v 重复不追加；顺序保持。
  auto slf4j = new Artifact("org.slf4j:slf4j-api:2.0.17", "org.slf4j", "slf4j-api",
      "2.0.17", "", "jar");
  auto local = new LocalFile("/opt/lib/x.jar", "/opt/lib/x.jar");
  auto engineCore = new Artifact("org.apache.tomcat.embed:tomcat-embed-core:11.0.21",
      "org.apache.tomcat.embed", "tomcat-embed-core", "11.0.21", "", "jar");
  auto engineSas = new Artifact("org.beangle.sas:beangle-sas-engine:0.13.10",
      "org.beangle.sas", "beangle-sas-engine", "0.13.10", "", "jar");
  auto remote = new RemoteFile("https://repo/x.jar", "https://repo/x.jar");

  auto merged = appendEngineDeps([cast(Archive) slf4j, local],
      [cast(Archive) engineCore, cast(Archive) slf4j, cast(Archive) engineSas, remote]);
  assert(merged.length == 5, merged.length.to!string);
  assert(cast(LocalFile) merged[1] !is null);
  assert(cast(Artifact) merged[2] is engineCore);
  assert(cast(Artifact) merged[3] is engineSas, "重复 slf4j 应被去重");
  assert(cast(RemoteFile) merged[4] !is null);
}
