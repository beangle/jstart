/**
 * Unit tests for jstart.engine: --entry-out argv 解析与引擎依赖合并去重。
 * jstart 不内置任何引擎目录、也不解析引擎入口类（入口是 spec 的 [engine] init
 * 脚本），故不再测试别名/FQCN 选择。
 *
 * Test code lives outside of source/, mirroring the beangle micdn layout.
 */
module test.jstart.engine_test;

import std.algorithm : canFind, startsWith;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.process : environment;
import std.string : endsWith;
import std.uuid : randomUUID;

import jstart.archive : Archive, Artifact, LocalFile, RemoteFile;
import jstart.engine : appendEngineDeps, argsFile, argvFile, engineDepsClasspathFile,
  entryClasspathFile, engineInitArgv, findOnPath, isProgramPath, parseCommandLine,
  parseEntryArgv, removeEngineWorkFiles, resolveEngineInit, subappsPlanFile, writeJstartArgv;

unittest {
  // --entry-out：NUL 分隔 argv；忽略结尾 NUL 与手写换行；保留中间空参数。
  assert(parseEntryArgv("") == []);
  assert(parseEntryArgv("java\0-cp\0a:b\0Main\0") == ["java", "-cp", "a:b", "Main"]);
  assert(parseEntryArgv("java\0-cp\0Main\n") == ["java", "-cp", "Main"]);
  assert(parseEntryArgv("a\0\0b") == ["a", "", "b"], "empty middle arg kept");
  assert(parseEntryArgv("solo") == ["solo"]);
}

unittest {
  // 非引擎模式：jstart 自己写 jstart.argv；长命令折成 jstart.args。
  auto dir = buildPath(tempDir(), "jstart-argv-" ~ randomUUID().toString);
  mkdirRecurse(dir);
  scope (exit)
    if (exists(dir))
      rmdirRecurse(dir);

  auto cmd = ["java", "-Xmx1g", "-cp", "a.jar", "Main"];
  auto actual = writeJstartArgv(dir, cmd);
  assert(actual == cmd);
  assert(readText(buildPath(dir, argvFile)) == "java\0-Xmx1g\0-cp\0a.jar\0Main\0");

  auto longArg = "-Dlong=";
  foreach (i; 0 .. 5000)
    longArg ~= "x";
  auto longCmd = ["java", longArg, "Main"];
  actual = writeJstartArgv(dir, longCmd);
  assert(actual.length == 2 && actual[1].startsWith("@"));
  assert(readText(buildPath(dir, argvFile)) == "java\0" ~ actual[1] ~ "\0");
  assert(readText(buildPath(dir, argsFile)).canFind("-Dlong="));
}

unittest {
  // 引擎依赖追加到应用依赖之后；g:a:v 重复不追加；顺序保持。
  auto slf4j = new Artifact("org.slf4j:slf4j-api:2.0.17", "org.slf4j", "slf4j-api",
      "2.0.17", "", "jar");
  auto local = new LocalFile("/opt/lib/x.jar", "/opt/lib/x.jar");
  auto engineCore = new Artifact("org.apache.tomcat.embed:tomcat-embed-core:11.0.21",
      "org.apache.tomcat.embed", "tomcat-embed-core", "11.0.21", "", "jar");
  auto engineBas = new Artifact("org.beangle.bas:beangle-bas-engine:0.13.17",
      "org.beangle.bas", "beangle-bas-engine", "0.13.17", "", "jar");
  auto remote = new RemoteFile("https://repo/x.jar", "https://repo/x.jar");

  auto merged = appendEngineDeps([cast(Archive) slf4j, local],
      [cast(Archive) engineCore, cast(Archive) slf4j, cast(Archive) engineBas, remote]);
  assert(merged.length == 5, merged.length.to!string);
  assert(cast(LocalFile) merged[1] !is null);
  assert(cast(Artifact) merged[2] is engineCore);
  assert(cast(Artifact) merged[3] is engineBas, "重复 slf4j 应被去重");
  assert(cast(RemoteFile) merged[4] !is null);
}

unittest {
  // base 下的约定文件名稳定：init 脚本按这些名字读写 plan/argv/classpath。
  assert(argvFile == "jstart.argv");
  assert(entryClasspathFile == "engine-app.classpath");
  assert(engineDepsClasspathFile == "engine-deps.classpath");
  assert(subappsPlanFile == "engine-subapps.jstart");
}

unittest {
  // 启动前清理：init 的输入文件删掉，argv 记录与 java @argfile 留下。
  auto dir = buildPath(tempDir(), "jstart-engine-cleanup-" ~ randomUUID().toString);
  mkdirRecurse(dir);
  scope (exit)
    if (exists(dir))
      rmdirRecurse(dir);
  foreach (name; [argvFile, argsFile, entryClasspathFile,
      engineDepsClasspathFile, subappsPlanFile])
    write(buildPath(dir, name), "x");

  removeEngineWorkFiles(dir);

  assert(!exists(buildPath(dir, engineDepsClasspathFile)));
  assert(!exists(buildPath(dir, entryClasspathFile)));
  assert(!exists(buildPath(dir, subappsPlanFile)));
  assert(exists(buildPath(dir, argvFile)), "removeEngineWorkFiles 不负责删 argv");
  assert(exists(buildPath(dir, argsFile)), "java @argfile 运行时还要读");
}

unittest {
  // [engine] init 命令分词：空白分隔、引号成组、反斜杠转义；不经过 shell。
  assert(parseCommandLine("") == []);
  assert(parseCommandLine("   ") == []);
  assert(parseCommandLine("/opt/bin/init") == ["/opt/bin/init"]);
  assert(parseCommandLine("engine-creator tomcat-server")
      == ["engine-creator", "tomcat-server"]);
  assert(parseCommandLine("/opt/my dir/init.sh") == ["/opt/my", "dir/init.sh"]);
  assert(parseCommandLine(`"/opt/my dir/init.sh"`) == ["/opt/my dir/init.sh"]);
  assert(parseCommandLine(`'/opt/my dir/init.sh'`) == ["/opt/my dir/init.sh"]);
  assert(parseCommandLine(`sh -c 'echo hi'`) == ["sh", "-c", "echo hi"]);
  assert(parseCommandLine(`a\ b`) == ["a b"]);
  assert(parseCommandLine(`""`) == [""]);
  assert(parseCommandLine("engine-creator tomcat-server  --port=1")
      == ["engine-creator", "tomcat-server", "--port=1"]);
}

unittest {
  // 程序 token 判定：含分隔符或 `.`/`~` 前缀按路径，否则按 PATH 查找。
  assert(isProgramPath("/opt/bin/init"));
  assert(isProgramPath("./init"));
  assert(isProgramPath("~/bin/init"));
  assert(!isProgramPath("engine-creator"));
  assert(!isProgramPath("java"));
  assert(findOnPath("sh").length > 0, "sh should be on PATH");
  assert(findOnPath("jstart-definitely-missing-cmd").length == 0);
}

unittest {
  // resolveEngineInit：路径缺失置 missing；裸命令名解析成 PATH 上的绝对路径。
  bool missing;
  auto absent = resolveEngineInit("/nonexistent/engine-init", missing);
  assert(absent == ["/nonexistent/engine-init"]);
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
