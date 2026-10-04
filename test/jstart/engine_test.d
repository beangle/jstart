/**
 * Unit tests for jstart.engine: --entry-out argv 解析与引擎依赖合并去重。
 * jstart 不内置任何引擎目录、也不解析引擎入口类（入口是 spec 的 [engine] init
 * 脚本），故不再测试别名/FQCN 选择。
 *
 * Test code lives outside of source/, mirroring the beangle micdn layout.
 */
module test.jstart.engine_test;

import std.conv : to;
import std.process : environment;
import std.string : endsWith;

import jstart.archive : Archive, Artifact, LocalFile, RemoteFile;
import jstart.engine : appendEngineDeps, engineDepsClasspathFile, entryArgvFile,
  entryClasspathFile, engineInitArgv, findOnPath, isProgramPath, parseCommandLine,
  parseEntryArgv, resolveEngineInit, subappsPlanFile;

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

unittest {
  // [engine] init 命令分词：空白分隔、引号成组、反斜杠转义；不经过 shell。
  assert(parseCommandLine("") == []);
  assert(parseCommandLine("   ") == []);
  assert(parseCommandLine("/opt/bin/init") == ["/opt/bin/init"]);
  assert(parseCommandLine("basctl make tomcat-dist")
      == ["basctl", "make", "tomcat-dist"]);
  assert(parseCommandLine("/opt/my dir/init.sh") == ["/opt/my", "dir/init.sh"]);
  assert(parseCommandLine(`"/opt/my dir/init.sh"`) == ["/opt/my dir/init.sh"]);
  assert(parseCommandLine(`'/opt/my dir/init.sh'`) == ["/opt/my dir/init.sh"]);
  assert(parseCommandLine(`sh -c 'echo hi'`) == ["sh", "-c", "echo hi"]);
  assert(parseCommandLine(`a\ b`) == ["a b"]);
  assert(parseCommandLine(`""`) == [""]);
  assert(parseCommandLine("basctl make tomcat-dist  --port=1")
      == ["basctl", "make", "tomcat-dist", "--port=1"]);
}

unittest {
  // 程序 token 判定：含分隔符或 `.`/`~` 前缀按路径，否则按 PATH 查找。
  assert(isProgramPath("/opt/bin/init"));
  assert(isProgramPath("./init"));
  assert(isProgramPath("~/bin/init"));
  assert(!isProgramPath("basctl"));
  assert(!isProgramPath("java"));
  assert(findOnPath("sh").length > 0, "sh should be on PATH");
  assert(findOnPath("jstart-definitely-missing-cmd").length == 0);
}

unittest {
  // resolveEngineInit：路径缺失置 missing；裸命令名解析成 PATH 上的绝对路径。
  bool missing;
  auto absent = resolveEngineInit("/nonexistent/basctl-init", missing);
  assert(absent == ["/nonexistent/basctl-init"]);
  assert(missing);

  bool shMissing;
  auto sh = resolveEngineInit("sh", shMissing);
  assert(!shMissing);
  assert(sh.length == 1 && isProgramPath(sh[0]) && sh[0].endsWith("/sh"));
}

unittest {
  // 变量展开发生在分词之后：展开出的空格仍属于同一个 argv。
  environment["JSTART_TEST_WORD"] = "a b";
  scope (exit) environment.remove("JSTART_TEST_WORD");
  assert(engineInitArgv("run ${JSTART_TEST_WORD} done") == ["run", "a b", "done"]);
}
