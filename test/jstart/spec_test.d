/**
 * Unit tests for jstart.spec: launch spec 识别与 ini 式解析。
 *
 * Test code lives outside of source/, mirroring the beangle micdn
 * layout. It is only compiled by the dub "unittest" configuration,
 * so released binaries never carry test code.
 */
module test.jstart.spec_test;

import std.array : join;
import std.string : indexOf, startsWith;

import jstart.spec : LaunchSpec, flattenLibs, isSpecFile, parseLaunchSpec, validateLaunchSpec;

unittest {
  // spec 识别：唯一形式是 .jstart 后缀（本地路径或 http(s) url，url 忽略查询串）。
  assert(isSpecFile("app.jstart"));
  assert(isSpecFile("/opt/x/app.jstart"));
  assert(isSpecFile("https://repo.example.com/app.jstart"));
  assert(isSpecFile("https://repo.example.com/app.jstart?token=abc"));
  assert(!isSpecFile("app.launch"));
  assert(!isSpecFile("deps.txt"));
  assert(!isSpecFile("app.jar"));
  assert(!isSpecFile("https://repo.example.com/app.jar"));
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
    "[libs]\n" ~
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
  assert(spec.libs.length == 1);
  assert(spec.libs[0] == "org.slf4j:slf4j-api:2.0.17");
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
  // 空 [libs] 段是空扩展（无副作用）；没有 [libs] 段则为空、走 entry 内置清单。
  string[] warnings;
  auto spec = parseLaunchSpec("[app]\nentry = x.jar\n[libs]\n", warnings);
  assert(spec.libs.length == 0);
  assert(warnings.length == 0);

  auto spec2 = parseLaunchSpec("[app]\nentry = x.jar\n", warnings);
  assert(spec2.libs.length == 0);

  // 旧名 [deps] 仍可用（告警 + 归入 libs），方便迁移。
  auto spec3 = parseLaunchSpec("[app]\nentry = x.jar\n[deps]\norg.slf4j:slf4j-api:2.0.17\n",
      warnings);
  assert(spec3.libs.length == 1);
  assert(warnings.length == 1);
  assert(warnings[0].indexOf("[deps]") >= 0 && warnings[0].indexOf("[libs]") >= 0);
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
    "[libs]\n" ~
    "  org.slf4j:slf4j-api:2.0.17  \n";
  string[] warnings;
  auto spec = parseLaunchSpec(text, warnings);
  assert(warnings.length == 0, warnings.join(","));
  assert(spec.runtimeOptions.length == 1 && spec.runtimeOptions[0] == "-Xmx1g");
  assert(spec.main == "M");
  assert(spec.entry == "x.jar");
  assert(spec.libs.length == 1 && spec.libs[0] == "org.slf4j:slf4j-api:2.0.17");
}

unittest {
  // [libs] 行原样保留（不去重、不解释）：与 deps file 的语义一致，重复由后续解析层处理。
  enum text = "[libs]\n" ~
    "org.slf4j:slf4j-api:2.0.17\n" ~
    "org.slf4j:slf4j-api:2.0.17\n" ~
    "https://repo.example.com/lib.jar\n";
  string[] warnings;
  auto spec = parseLaunchSpec(text, warnings);
  assert(spec.libs.length == 3, spec.libs.join(","));
  assert(spec.libs[1] == "org.slf4j:slf4j-api:2.0.17");
  assert(spec.libs[2] == "https://repo.example.com/lib.jar");
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
  // [app] engine 短键 + [engine] 段：war 引擎选择与引擎依赖罗列（每行同 [libs] 语法）。
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

unittest {
  // [app] main 与 [app] engine / [engine] 互斥，由 validateLaunchSpec 报错
  string[] warnings;
  auto withEngine = parseLaunchSpec(
      "[app]\nentry = app.war\nmain = org.example.Main\nengine = tomcat\n", warnings);
  assert(validateLaunchSpec(withEngine).length > 0);

  auto withEngineDeps = parseLaunchSpec(
      "[app]\nentry = app.war\nmain = org.example.Main\n[engine]\n", warnings);
  assert(validateLaunchSpec(withEngineDeps).length > 0);

  auto mainOnly = parseLaunchSpec("[app]\nentry = app.jar\nmain = org.example.Main\n", warnings);
  assert(validateLaunchSpec(mainOnly).length == 0);

  auto engineOnly = parseLaunchSpec("[app]\nentry = app.war\nengine = tomcat\n", warnings);
  assert(validateLaunchSpec(engineOnly).length == 0);
}

unittest {
  // 多应用：[subapp <id>] 段逐个声明 entry/path；重复的 id 由段头 id 决定。
  enum text = "[app]\nbase = /var/tmp/jstart/demo\n" ~
    "[subapp portal]\n" ~
    "entry = portal.war\n" ~
    "path = /portal\n" ~
    "libs = com.zaxxer:HikariCP:7.0.3-SNAPSHOT\n" ~
    "[subapp admin]\n" ~
    "entry = admin.war\n" ~
    "path = /admin/\n";
  string[] warnings;
  auto spec = parseLaunchSpec(text, warnings);
  assert(warnings.length == 0, warnings.join(","));
  assert(spec.subapps.length == 2);
  assert(spec.subapps[0].id == "portal");
  assert(spec.subapps[0].entry == "portal.war");
  assert(spec.subapps[0].path == "/portal");
  assert(spec.subapps[0].libs.length == 1);
  assert(spec.subapps[0].libs[0] == "com.zaxxer:HikariCP:7.0.3-SNAPSHOT");
  assert(spec.subapps[1].id == "admin");
  assert(spec.subapps[1].entry == "admin.war");
  assert(spec.subapps[1].path == "/admin/");
  assert(spec.subapps[1].libs.length == 0);
  assert(spec.base == "/var/tmp/jstart/demo");
  assert(validateLaunchSpec(spec).length == 0, validateLaunchSpec(spec));
}

unittest {
  // libs 展开：一行可逗号/分号分隔多个，多行累加，空白与空项被丢弃。
  assert(flattenLibs(["org.slf4j:slf4j-api:2.0.17"]).length == 1);
  auto multi = flattenLibs(["a:b:1, c:d:2;e:f:3", "  ", "g:h:4"]);
  assert(multi.length == 4);
  assert(multi[0] == "a:b:1");
  assert(multi[1] == "c:d:2");
  assert(multi[2] == "e:f:3");
  assert(multi[3] == "g:h:4");
}

unittest {
  // [subapp] 段头缺 id 或未知键：告警但不崩，spec.subapps 只收有效段。
  string[] warnings;
  auto spec = parseLaunchSpec("[subapp]\nentry = a.war\n", warnings);
  assert(spec.subapps.length == 0);
  assert(warnings.length == 1);

  warnings = null;
  spec = parseLaunchSpec("[subapp portal]\nentry = a.war\nweird = x\n", warnings);
  assert(spec.subapps.length == 1);
  assert(warnings.length == 1);
  assert(warnings[0].indexOf("unknown [subapp] key") >= 0);
}

unittest {
  // 多应用校验：每个 subapp 需要 entry 和 path，缺一不可。
  string[] warnings;
  auto noPath = parseLaunchSpec("[subapp a]\nentry = a.war\n", warnings);
  assert(validateLaunchSpec(noPath).length > 0);

  auto noEntry = parseLaunchSpec("[subapp a]\npath = /a\n", warnings);
  assert(validateLaunchSpec(noEntry).length > 0);

  auto ok = parseLaunchSpec("[subapp a]\nentry = a.war\npath = /a\n", warnings);
  assert(validateLaunchSpec(ok).length == 0);
}

unittest {
  // 归一化后重复的 context path（/a、/a/、a）视为冲突；id 也不能重复。
  string[] warnings;
  auto dupPath = parseLaunchSpec(
      "[subapp a]\nentry = a.war\npath = /a\n[subapp b]\nentry = b.war\npath = /a/\n",
      warnings);
  assert(validateLaunchSpec(dupPath).length > 0);

  auto dupRoot = parseLaunchSpec(
      "[subapp a]\nentry = a.war\npath = /\n[subapp b]\nentry = b.war\npath = /\n", warnings);
  assert(validateLaunchSpec(dupRoot).length > 0);

  auto dupId = parseLaunchSpec(
      "[subapp a]\nentry = a.war\npath = /a\n[subapp a]\nentry = b.war\npath = /b\n",
      warnings);
  assert(validateLaunchSpec(dupId).length > 0);

  auto badId = parseLaunchSpec("[subapp a b]\nentry = a.war\npath = /a\n", warnings);
  assert(validateLaunchSpec(badId).length > 0);
}

unittest {
  // 多应用与单应用的键互斥：entry/main/[libs] 都不能和 [subapp] 段共存。
  string[] warnings;
  auto withEntry = parseLaunchSpec(
      "[app]\nentry = app.war\n[subapp a]\nentry = a.war\npath = /a\n", warnings);
  assert(validateLaunchSpec(withEntry).length > 0);

  auto withMain = parseLaunchSpec(
      "[app]\nmain = org.example.Main\n[subapp a]\nentry = a.war\npath = /a\n", warnings);
  assert(validateLaunchSpec(withMain).length > 0);

  auto withLibs = parseLaunchSpec(
      "[libs]\norg.slf4j:slf4j-api:2.0.17\n[subapp a]\nentry = a.war\npath = /a\n", warnings);
  assert(validateLaunchSpec(withLibs).length > 0);
}

unittest {
  // 多应用必须走 Dist 模式：内置别名与 *EmbedCreator 都被拒绝，ServerCreator FQCN 放行。
  string[] warnings;
  auto aliasEngine = parseLaunchSpec(
      "[app]\nengine = tomcat\n[subapp a]\nentry = a.war\npath = /a\n", warnings);
  assert(validateLaunchSpec(aliasEngine).length > 0);

  auto embed = parseLaunchSpec(
      "[app]\nengine = org.beangle.sas.engine.tomcat.EmbedCreator\n"
      ~ "[subapp a]\nentry = a.war\npath = /a\n", warnings);
  assert(validateLaunchSpec(embed).length > 0);

  auto dist = parseLaunchSpec(
      "[app]\nengine = org.beangle.sas.engine.tomcat.ServerCreator\n"
      ~ "[subapp a]\nentry = a.war\npath = /a\n", warnings);
  assert(validateLaunchSpec(dist).length == 0, validateLaunchSpec(dist));

  // engine 缺省（空）留给 run 层选 ServerCreator；[engine] 依赖段与 [subapp] 段兼容。
  auto defaulted = parseLaunchSpec(
      "[subapp a]\nentry = a.war\npath = /a\n[engine]\n"
      ~ "org.beangle.sas:beangle-sas-engine:0.13.17\n", warnings);
  assert(validateLaunchSpec(defaulted).length == 0, validateLaunchSpec(defaulted));
}
