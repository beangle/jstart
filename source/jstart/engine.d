/**
 * The engine "init script" protocol and engine classpath helpers.
 *
 * A war cannot be launched by a Main-Class: jstart hands the war (a war file
 * or an already-exploded directory) to an **engine init script**, an
 * executable that prepares the container environment, writes the final
 * launch command to a file and exits. jstart then execs that command. The
 * war is therefore never exploded by jstart - the engine owns the docBase
 * layout and the explosion, so that formula lives in exactly one place
 * (the engine). See docs/engine.md for the full protocol.
 *
 * The engine entry is declared in the launch spec; jstart ships **no**
 * built-in engine catalog, so it never favours one particular container:
 *
 *   [engine]
 *   init = /opt/engine/bin/acme-tomcat-init         # 必填：可执行文件路径
 *   init = basctl make tomcat-dist                # 或命令行（程序 + 参数）
 *   org.beangle.bas:beangle-bas-engine:0.13.17      # 引擎 jar（同 [libs] 语法，可选）
 *   org.apache.tomcat.embed:tomcat-embed-core:11.0.21
 *
 * The `init` value is a command line (an executable path, optionally with
 * arguments), never a java class; the entry jars come from the other
 * `[engine]` lines. A spec is an engine target exactly when it declares an
 * [engine] section (see jstart.spec.launchType).
 */
module jstart.engine;

import std.algorithm : endsWith;
import std.array : split;
import std.file : exists, isFile;
import std.path : buildPath;
import std.process : environment;
import std.string : indexOf, startsWith;

import jstart.archive : Archive, Artifact, expandLocalPath;

/**
 * Append engine jars after the application dependencies. An engine gav
 * already listed among the application deps is not duplicated (compared
 * by group:artifact:version).
 */
Archive[] appendEngineDeps(Archive[] appDeps, Archive[] engineDeps) {
  Archive[] result = appDeps.dup;
  foreach (ed; engineDeps) {
    auto a = cast(Artifact) ed;
    if (a is null) {
      result ~= ed;
      continue;
    }
    auto dup = false;
    foreach (ad; result) {
      auto b = cast(Artifact) ad;
      if (b !is null && b.groupId == a.groupId && b.artifactId == a.artifactId
          && b.ver == a.ver) {
        dup = true;
        break;
      }
    }
    if (!dup) {
      result ~= ed;
    }
  }
  return result;
}

/// File under the component base where the engine init script writes the final argv.
immutable string entryArgvFile = "engine-entry.argv";

/// File under the component base holding the application dependency classpath.
/// The classpath can be very long, so it is handed to the engine init script
/// via --app-classpath-file instead of on the command line.
immutable string entryClasspathFile = "engine-app.classpath";

/// File under the component base holding the engine's own dependency classpath
/// (the jars listed in the spec's [engine] section, excluding `init`). It is
/// handed to the engine init script via --engine-classpath-file so the script
/// can decide how to compose the final command.
immutable string engineDepsClasspathFile = "engine-deps.classpath";

/**
 * File under the component base describing the subapps an engine must deploy
 * (multi-app specs). It is a launch-spec fragment written by jstart, one
 * `[subapp <id>]` section per webapp:
 *
 *   [subapp portal]
 *   entry = /abs/path/portal.war     # 本地 war 文件或已解压目录
 *   path  = /portal                  # 上下文路径（引擎归一化后建 Context）
 *   libs  = g:a:v,g2:a2:v2           # 可选：扩展依赖（引擎合并到 war 清单之上）
 *
 * The entry path is a local war file or an already exploded directory; the
 * context path is the spec's `[subapp <id>] path` value; libs are the extra
 * gavs the engine's per-Context DependencyClassLoader merges over the war's
 * own `META-INF/beangle/dependencies`. It is not passed on the command line:
 * the engine init script reads <base>/engine-subapps.jstart from the --base
 * it was given.
 */
immutable string subappsPlanFile = "engine-subapps.jstart";

/**
 * `[engine] init` 的取值既可以是**可执行文件路径**，也可以是**命令行**（程序 + 参数）：
 *
 *   init = /opt/engine/bin/acme-tomcat-init     # 可执行文件/脚本路径
 *   init = basctl make tomcat-dist            # 命令行
 *   init = "/opt/my dir/init.sh" --flag         # 带引号与参数
 *
 * 命令行按 shell 规则分词（空白分隔，单/双引号成组，反斜杠转义），但**不经过 shell**：
 * 没有管道/重定向/通配符，需要时自己写 `sh -c '...'`。分词后再对每个 token 做
 * `~`/`${VAR}` 展开，因此变量展开出的空格不会把参数拆开。
 */

/// 按 shell 规则把 `[engine] init` 的值切成 argv（不展开变量，调用方再处理）。
string[] parseCommandLine(string line) {
  string[] argv;
  char[] cur;
  bool started;
  enum State { plain, single, double_ }
  auto state = State.plain;
  size_t i;
  while (i < line.length) {
    auto c = line[i];
    final switch (state) {
      case State.plain:
        if (c == ' ' || c == '\t') {
          if (started) {
            argv ~= cur.idup;
            cur.length = 0;
            started = false;
          }
        } else if (c == '\'') {
          started = true;
          state = State.single;
        } else if (c == '"') {
          started = true;
          state = State.double_;
        } else if (c == '\\' && i + 1 < line.length) {
          started = true;
          ++i;
          cur ~= line[i];
        } else {
          started = true;
          cur ~= c;
        }
        break;
      case State.single:
        if (c == '\'') {
          state = State.plain;
        } else {
          cur ~= c;
        }
        break;
      case State.double_:
        if (c == '"') {
          state = State.plain;
        } else if (c == '\\' && i + 1 < line.length) {
          ++i;
          cur ~= line[i];
        } else {
          cur ~= c;
        }
        break;
    }
    ++i;
  }
  if (started) {
    argv ~= cur.idup;
  }
  return argv;
}

/// `[engine] init` → argv：分词后对每个 token 展开 `~`/`${VAR}`。
string[] engineInitArgv(string initValue) {
  auto argv = parseCommandLine(initValue);
  foreach (ref a; argv) {
    a = expandLocalPath(a);
  }
  return argv;
}

/// 程序 token 是否按路径解析（含分隔符，或以 `.`/`~` 开头）；否则按 PATH 查找。
bool isProgramPath(string program) {
  return program.indexOf('/') >= 0 || program.indexOf('\\') >= 0
      || program.startsWith(".") || program.startsWith("~");
}

/// 在 PATH 上查找裸命令名（Windows 追加 PATHEXT）；找不到返回 ""。
string findOnPath(string name) {
  version (Windows) {
    immutable string[] exts = environment.get("PATHEXT", ".COM;.EXE;.BAT;.CMD").split(";");
    immutable sep = ';';
  } else {
    immutable string[] exts = [""];
    immutable sep = ':';
  }
  foreach (dir; environment.get("PATH", "").split(sep)) {
    if (dir.length == 0) {
      continue;
    }
    foreach (ext; exts) {
      auto candidate = buildPath(dir, name ~ ext);
      if (exists(candidate) && isFile(candidate)) {
        return candidate;
      }
    }
  }
  return "";
}

/**
 * 解析 `[engine] init`：返回要执行的 argv（裸命令名解析成 PATH 上的绝对路径）。
 * `missing` 表示程序没找到（路径不存在，或裸名不在 PATH 上）；`--print` 可忽略它。
 */
string[] resolveEngineInit(string initValue, out bool missing) {
  auto argv = engineInitArgv(initValue);
  missing = argv.length == 0;
  if (missing) {
    return argv;
  }
  if (isProgramPath(argv[0])) {
    missing = !exists(argv[0]) || !isFile(argv[0]);
  } else {
    auto found = findOnPath(argv[0]);
    if (found.length == 0) {
      missing = true;
    } else {
      argv[0] = found;
    }
  }
  return argv;
}

/**
 * Parse the NUL-separated argv an engine init script wrote to its
 * --entry-out file. A trailing NUL (and an optional final newline added by
 * hand) is ignored; empty arguments in the middle are preserved.
 */
string[] parseEntryArgv(string text) {
  string[] argv;
  foreach (part; text.split('\0')) {
    auto p = part;
    if (p.endsWith("\r\n")) {
      p = p[0 .. $ - 2];
    } else if (p.endsWith("\n") || p.endsWith("\r")) {
      p = p[0 .. $ - 1];
    }
    argv ~= p;
  }
  while (argv.length > 0 && argv[$ - 1].length == 0) {
    argv = argv[0 .. $ - 1];
  }
  return argv;
}
