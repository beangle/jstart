/**
 * Unit tests for jstart.spec: launch spec 识别与 ini 式解析。
 *
 * Test code lives outside of source/, mirroring the beangle micdn
 * layout. It is only compiled by the dub "unittest" configuration,
 * so released binaries never carry test code.
 */
module test.jstart.spec_test;

import std.array : join;
import std.string : startsWith;

import jstart.spec : LaunchSpec, isLaunchSpecText, isSpecFile, parseLaunchSpec;

unittest {
  assert(isSpecFile("app.launch"));
  assert(isSpecFile("/opt/x/app.jstart"));
  assert(!isSpecFile("deps.txt"));
  assert(!isSpecFile("app.jar"));

  assert(isLaunchSpecText("[app]\nentry = x.jar\n"));
  assert(isLaunchSpecText("# comment\n\n[app]\n"));
  assert(!isLaunchSpecText("org.slf4j:slf4j-api:2.0.17\n"));
  assert(!isLaunchSpecText("# only comments\n\n"));
  assert(!isLaunchSpecText(""));
}

unittest {
  enum text = "# launch spec\n" ~
    "[app]\n" ~
    "main = org.example.Main\n" ~
    "entry = gav://org.example:app:1.0\n" ~
    "working_dir = ${BASE}/run\n" ~
    "\n" ~
    "[runtime]\n" ~
    "-Xmx512m\n" ~
    "-Dfile.encoding=UTF-8\n" ~
    "[args]\n" ~
    "--port=8080\n" ~
    "with space\n" ~
    "; trailing comment line\n" ~
    "[deps]\n" ~
    "org.slf4j:slf4j-api:2.0.17\n";
  string[] warnings;
  auto spec = parseLaunchSpec(text, warnings);
  assert(warnings.length == 0, warnings.join(","));
  assert(spec.main == "org.example.Main");
  assert(spec.entry == "gav://org.example:app:1.0");
  assert(spec.workingDir == "${BASE}/run");
  assert(spec.runtimeOptions.length == 2);
  assert(spec.runtimeOptions[0] == "-Xmx512m");
  assert(spec.runtimeOptions[1] == "-Dfile.encoding=UTF-8");
  assert(spec.args.length == 2);
  assert(spec.args[0] == "--port=8080");
  assert(spec.args[1] == "with space");
  assert(spec.hasDeps);
  assert(spec.deps.length == 1);
  assert(spec.deps[0] == "org.slf4j:slf4j-api:2.0.17");
}

unittest {
  // 重复标量取最后值；未知段/未知键告警并忽略。
  enum text = "[app]\n" ~
    "main = A\n" ~
    "main = B\n" ~
    "entry = x.jar\n" ~
    "bogus = 1\n" ~
    "noequals\n" ~
    "[future]\n" ~
    "entry = ignored\n" ~
    "[args]\n" ~
    "-a\n";
  string[] warnings;
  auto spec = parseLaunchSpec(text, warnings);
  assert(spec.main == "B");
  assert(spec.entry == "x.jar");
  assert(spec.args.length == 1 && spec.args[0] == "-a");
  assert(warnings.length == 3, warnings.join(","));
}

unittest {
  // 空 [deps] 段：显式声明"无依赖"，hasDeps 为 true。
  string[] warnings;
  auto spec = parseLaunchSpec("[app]\nentry = x.jar\n[deps]\n", warnings);
  assert(spec.hasDeps);
  assert(spec.deps.length == 0);
  assert(warnings.length == 0);

  // 没有 [deps] 段：hasDeps 为 false（回退读取 entry 内置清单）。
  auto spec2 = parseLaunchSpec("[app]\nentry = x.jar\n", warnings);
  assert(!spec2.hasDeps);
  assert(spec2.deps.length == 0);
}

unittest {
  // 告警携带准确行号；未知段整段跳过、后续已知段不受影响。
  enum text = "# head\n" ~
    "[app]\n" ~
    "unknown = 1\n" ~
    "[future]\n" ~
    "main = X\n" ~
    "[app]\n" ~
    "main = Y\n" ~
    "[args]\n" ~
    "-a\n";
  string[] warnings;
  auto spec = parseLaunchSpec(text, warnings);
  assert(spec.main == "Y");
  assert(spec.args.length == 1 && spec.args[0] == "-a");
  assert(warnings.length == 2, warnings.join(","));
  assert(warnings[0] == "line 3: unknown [app] key unknown", warnings[0]);
  assert(warnings[1] == "line 4: unknown section [future]", warnings[1]);
}

unittest {
  // 段可乱序出现；值两侧空白裁剪；段内整行注释被忽略。
  enum text = "[runtime]\n" ~
    "  -Xmx1g  \n" ~
    "[app]\n" ~
    " main = M \n" ~
    "entry=  x.jar\t\n" ~
    "; whole line comment\n" ~
    "# another\n" ~
    "[deps]\n" ~
    "  org.slf4j:slf4j-api:2.0.17  \n";
  string[] warnings;
  auto spec = parseLaunchSpec(text, warnings);
  assert(warnings.length == 0, warnings.join(","));
  assert(spec.runtimeOptions.length == 1 && spec.runtimeOptions[0] == "-Xmx1g");
  assert(spec.main == "M");
  assert(spec.entry == "x.jar");
  assert(spec.hasDeps);
  assert(spec.deps.length == 1 && spec.deps[0] == "org.slf4j:slf4j-api:2.0.17");
}

unittest {
  // sniffing 边界：首行空白/注释后可判定；首个内容行非段头则判为普通清单。
  assert(isLaunchSpecText("\n\n[args]\n-x\n"));
  assert(isLaunchSpecText("; comment\n; more\n[app]\n"));
  assert(isLaunchSpecText("[app]"));
  assert(!isLaunchSpecText("  org.slf4j:slf4j-api:2.0.17\n"));
  assert(!isLaunchSpecText("entry = x.jar\n[app]\n"));
  assert(!isLaunchSpecText("--port=8080\n[app]\n"));
}

unittest {
  // 常见两种依赖行前缀在 sniffing 时都不会被误判为 spec。
  assert(!isLaunchSpecText("gav://org.slf4j:slf4j-api:2.0.17\n"));
  assert(!isLaunchSpecText("https://repo.example.com/lib.jar\n"));
  assert(!isLaunchSpecText("/opt/lib/x.jar\n"));
}

unittest {
  // [deps] 行原样保留（不去重、不解释）：与 deps file 的语义一致，重复由后续解析层处理。
  enum text = "[deps]\n" ~
    "org.slf4j:slf4j-api:2.0.17\n" ~
    "org.slf4j:slf4j-api:2.0.17\n" ~
    "https://repo.example.com/lib.jar\n";
  string[] warnings;
  auto spec = parseLaunchSpec(text, warnings);
  assert(spec.hasDeps);
  assert(spec.deps.length == 3, spec.deps.join(","));
  assert(spec.deps[1] == "org.slf4j:slf4j-api:2.0.17");
  assert(spec.deps[2] == "https://repo.example.com/lib.jar");
}

unittest {
  // 未知段先于/后于已知段均告警并忽略；[app] 内无 '=' 的行按格式错误告警。
  enum text = "[meta]\n" ~
    "x = 1\n" ~
    "[app]\n" ~
    "main\n" ~
    "main = A\n";
  string[] warnings;
  auto spec = parseLaunchSpec(text, warnings);
  assert(spec.main == "A");
  assert(warnings.length == 2, warnings.join(","));
  assert(warnings[0].startsWith("line 1: unknown section"), warnings[0]);
  assert(warnings[1].startsWith("line 4: [app] expects key = value"), warnings[1]);
}

unittest {
  // [app] runtime 键：显式声明运行时/解释器可执行文件（不做展开，由 run 层处理）。
  enum text = "[app]\n" ~
    "runtime = /opt/jdk21/bin/java\n" ~
    "main = M\n" ~
    "working_dir = ${BASE}\n";
  string[] warnings;
  auto spec = parseLaunchSpec(text, warnings);
  assert(warnings.length == 0, warnings.join(","));
  assert(spec.runtime == "/opt/jdk21/bin/java");
  assert(spec.main == "M");
  assert(spec.workingDir == "${BASE}");
}

unittest {
  // 旧命名已移除：`[jvm]` 段与 `[app] java` 键视为未知并告警（干净改名，不兼容旧名）。
  enum text = "[app]\n" ~
    "java = /old/bin/java\n" ~
    "main = M\n" ~
    "[jvm]\n" ~
    "-Xmx1g\n";
  string[] warnings;
  auto spec = parseLaunchSpec(text, warnings);
  assert(spec.runtime.length == 0);
  assert(spec.runtimeOptions.length == 0);
  assert(spec.main == "M");
  assert(warnings.length == 2, warnings.join(","));
  assert(warnings[0].startsWith("line 2: unknown [app] key java"), warnings[0]);
  assert(warnings[1].startsWith("line 4: unknown section [jvm]"), warnings[1]);
}

unittest {
  // [app] engine 短键 + [engine] 段：war 引擎选择与引擎依赖罗列（每行同 [deps] 语法）。
  enum text = "[app]\n" ~
    "entry = app.war\n" ~
    "engine = tomcat\n" ~
    "[engine]\n" ~
    "org.beangle.sas:beangle-sas-engine:0.13.10\n" ~
    "org.apache.tomcat.embed:tomcat-embed-core:11.0.21\n" ~
    "[args]\n" ~
    "--port=8080\n";
  string[] warnings;
  auto spec = parseLaunchSpec(text, warnings);
  assert(warnings.length == 0, warnings.join(","));
  assert(spec.engine == "tomcat");
  assert(spec.hasEngineDeps);
  assert(spec.engineDeps.length == 2, spec.engineDeps.join(","));
  assert(spec.engineDeps[0] == "org.beangle.sas:beangle-sas-engine:0.13.10");
  assert(spec.engineDeps[1] == "org.apache.tomcat.embed:tomcat-embed-core:11.0.21");
  assert(spec.args.length == 1 && spec.args[0] == "--port=8080");
}

unittest {
  // 空 [engine] 段：显式声明"引擎无额外依赖/以罗列为准"，hasEngineDeps 为 true。
  string[] warnings;
  auto spec = parseLaunchSpec("[app]\nentry = app.war\nengine = tomcat\n[engine]\n", warnings);
  assert(spec.engine == "tomcat");
  assert(spec.hasEngineDeps);
  assert(spec.engineDeps.length == 0);
  assert(warnings.length == 0);

  // 没有 [engine] 段：hasEngineDeps 为 false（回退内置默认目录）。
  auto spec2 = parseLaunchSpec("[app]\nentry = app.war\nengine = tomcat\n", warnings);
  assert(spec2.engine == "tomcat");
  assert(!spec2.hasEngineDeps);
  assert(spec2.engineDeps.length == 0);
}

unittest {
  // jar 目标可以不声明 engine：[app] engine 缺省为空，由 run 层按目标类型决定。
  enum text = "[app]\nentry = app.jar\nmain = org.example.Main\n";
  string[] warnings;
  auto spec = parseLaunchSpec(text, warnings);
  assert(spec.engine.length == 0);
  assert(!spec.hasEngineDeps);
  assert(warnings.length == 0);
}
