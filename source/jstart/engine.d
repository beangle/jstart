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
 *   init = /opt/engine/bin/acme-tomcat-init     # 必填：引擎入口脚本（文件路径）
 *   org.beangle.sas:beangle-sas-engine:0.13.17  # 引擎 jar（同 [libs] 语法，可选）
 *   org.apache.tomcat.embed:tomcat-embed-core:11.0.21
 *
 * The `init` value is a script/executable file path, never a java class;
 * the entry jars come from the other `[engine]` lines. A spec is an engine
 * target exactly when it declares an [engine] section (see
 * jstart.spec.launchType).
 */
module jstart.engine;

import std.algorithm : endsWith;
import std.array : split;

import jstart.archive : Archive, Artifact;

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
