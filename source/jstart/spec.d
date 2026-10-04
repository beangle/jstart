/**
 * Launch spec files: an ini-like description of how to start an application.
 *
 * A spec declares the main class (Java only), the application entry
 * (gav/http/file/dir), the runtime executable and its options, application
 * args, an optional extension libs list (`[libs]`, merged over the entry's
 * built-in dependency manifest) and, for engine targets, an `[engine]`
 * section holding an `init` script (the engine entry point) plus the engine
 * jars (see docs/engine.md), turning `run` into a complete
 * "how to start" description. A spec may instead declare several
 * `[subapp <id>]` sections (entry + context path + optional extension libs)
 * so one engine runs several webapps in one JVM.
 * The parsed result also carries a derived launch type (`app`/`engine`):
 * it is not a spec key but a conclusion drawn by jstart from whether the
 * spec declares an engine, so callers can branch on "run an application"
 * vs "run through an engine" (see `launchType`).
 * See docs/launch-spec.md for the format and design decisions.
 */
module jstart.spec;

import std.algorithm : canFind, endsWith;
import std.array : split;
import std.format : format;
import std.string : indexOf, replace, startsWith, strip;

import jstart.base : isSafeInstanceName;

/// Launch spec suffix: a spec target must be named <name>.jstart.
immutable string[] specExtensions = [".jstart"];

/**
 * 启动模型：jstart 由**解析结果**推导的目标类型，故意不写成 spec 键。
 *
 * - `app`：直接 exec 运行时——java 跑 jar/解压目录，或 native（tar.gz）可执行文件；
 * - `engine`：先跑 spec 的**引擎 init 命令**准备容器环境（解压 war/发行包、写容器
 *   配置），再 exec 它写出的命令。
 *
 * 判定只看**是否声明了引擎**（`[engine]` 段，或 `[subapp <id>]` 多 webapp）；
 * jstart 不再从 war 后缀之类反推，也不内置任何引擎目录——没有声明引擎就是普通 `app`。
 */
enum LaunchType {
  app,
  engine,
}

/// LaunchType 的稳定文本名（`info` 输出与日志用）。
string launchTypeName(LaunchType t) {
  return t == LaunchType.engine ? "engine" : "app";
}

/// 单个 subapp 的声明（`[subapp <id>]` 段）：一个引擎跑多个应用时用。
struct SubappSpec {
  /// 段头里的 id（`[subapp portal]` → "portal"）：命名计划行，便于引擎区分各 subapp。
  string id;
  /// 应用入口，取值同 [app] entry（gav / url / 本地文件 / 目录）。
  string entry;
  /// 上下文路径；多 app 必填、归一化后各自唯一（`/` 只能有一个）。
  string path;
  /// 扩展依赖（`libs = g:a:v`，可多行、一行可逗号分隔多个）：追加在该 webapp 的
  /// META-INF/beangle/dependencies 清单之上（同名 g:a 以 libs 为准），由引擎的
  /// DependencyClassLoader 合并；jstart 负责把它们先取回本地仓库。
  string[] libs;
}

/// A parsed launch spec.
struct LaunchSpec {
  /// Main class; empty when the entry's own manifest provides it.
  string main;
  /// Application entry: g:a:v | gav:// | http(s):// | local file/dir path.
  string entry;
  /// Working directory to chdir into before exec; "" means "keep cwd".
  string workingDir;
  /// Runtime/interpreter executable (java, python3, node, ...); "" makes
  /// the launcher infer one from the entry (a jar runs with java).
  string runtime;
  /// Executable inside a native (tar.gz) entry, relative to its extraction
  /// root; "" makes the launcher look for the usual <name>/bin/<executable>
  /// layout. Ignored by jar/war entries.
  string exec;
  /// Component base directory ("" = the default under the jstart base root):
  /// the pid file, the native extraction and the war explosion all live below
  /// it. One base runs one instance of a component.
  string base;
  /// [app] instance: explicit component directory name below the base root,
  /// used verbatim (<root>/<instance>). Without it the directory key is
  /// derived from the target. Must be a safe path segment; optional.
  string instance;
  /// Runtime options, in order (each spec line is one option; java -X/-D,
  /// python -O, ...).
  string[] runtimeOptions;
  /// Application args, in order (each spec line is one argv, no splitting).
  string[] args;
  /// 扩展依赖行（`[libs]` 段）：追加/覆盖在 entry 内置依赖清单之上。同名按
  /// `groupId:artifactId` 判定（不看版本），同名时取 libs 的版本。每行与依赖描述
  /// 文件同语法（gav/本地文件/远程 url）；一行也可逗号分隔多个 gav。native 等
  /// 无内置清单的 entry 下它就是全部依赖。
  string[] libs;
  /// Engine entry ([engine] init = <path|command>): the engine's init program.
  /// jstart runs it to prepare the container and write the final launch
  /// command; it is a script path or a command line, never a java class.
  string engineInit;
  /// Engine dependency lines ([engine] section, excluding `init`), same
  /// syntax as [libs].
  string[] engineDeps;
  /// Whether an [engine] section was present. It is the only source of
  /// engine jars and of the init command: jstart ships no built-in catalog,
  /// so engine targets must have this set (see jstart.engine).
  bool hasEngine;
  /// 多应用：[subapp <id>] 段逐个声明，空表示单应用 spec（[app] entry）。
  SubappSpec[] subapps;

  /// 见文件级 `launchType`：由解析结果（而非 spec 键）推导的启动模型。
  LaunchType type() const {
    return launchType(this);
  }
}

/**
 * 由解析结果推导启动模型 `LaunchType`：**声明了引擎才是 engine**。
 *
 * engine 的判据：存在 `[engine]` 段、或有 `[subapp <id>]` 多 webapp（多应用本质
 * 就是引擎目标）。其余一律 app。jstart 不从 entry 的 `.war` 后缀反推 engine，也不
 * 内置引擎目录——war 想跑就必须显式声明引擎。
 */
LaunchType launchType(in LaunchSpec spec) {
  if (spec.subapps.length > 0 || spec.hasEngine) {
    return LaunchType.engine;
  }
  return LaunchType.app;
}

/**
 * Whether the target is a launch spec: the only accepted form is a
 * `.jstart` suffix, on a local path or an http(s) url (a query string on
 * the url is ignored). Content sniffing and other extensions are not
 * treated as spec markers anymore.
 */
bool isSpecFile(string path) {
  auto q = path.indexOf("?");
  if (q >= 0) {
    path = path[0 .. q];
  }
  foreach (ext; specExtensions) {
    if (path.endsWith(ext)) {
      return true;
    }
  }
  return false;
}

/**
 * Parse launch spec content. Scalar keys (main/entry/working_dir) keep the
 * last value; list sections keep every line verbatim. Unknown sections and
 * keys are reported in warnings and ignored so that future sections stay
 * compatible.
 */
LaunchSpec parseLaunchSpec(string content, out string[] warnings) {
  LaunchSpec spec;
  string section = "";
  foreach (i, lineRaw; content.split("\n")) {
    auto raw = lineRaw.strip;
    if (raw.length == 0 || raw.startsWith("#") || raw.startsWith(";")) {
      continue;
    }
    if (raw.startsWith("[") && raw.endsWith("]")) {
      auto name = raw[1 .. $ - 1].strip;
      if (name == "subapp" || name.startsWith("subapp ")) {
        auto id = name["subapp".length .. $].strip;
        if (id.length == 0) {
          warnings ~= format("line %d: [subapp] needs an id, e.g. [subapp portal]", i + 1);
          section = "";
        } else {
          spec.subapps ~= SubappSpec(id, "", "");
          section = "subapp";
        }
        continue;
      }
      section = name;
      if (section == "deps") {
        // 旧名 [deps]：0.0.x 起改名 [libs]，语义也从"替换内置清单"改为"追加/覆盖"。
        warnings ~= format("line %d: [deps] 已改名为 [libs]，请更新 spec", i + 1);
        section = "libs";
      } else if (section == "engine") {
        spec.hasEngine = true; // [engine] 段存在即为准
      } else if (section != "app" && section != "runtime" && section != "args"
          && section != "libs") {
        warnings ~= format("line %d: unknown section [%s]", i + 1, section);
        section = ""; // 未知段内容整段跳过
      }
      continue;
    }
    if (section.length == 0) {
      continue;
    }
    switch (section) {
      case "app":
        auto eq = raw.indexOf("=");
        if (eq < 0) {
          warnings ~= format("line %d: [app] expects key = value", i + 1);
          continue;
        }
        auto key = raw[0 .. eq].strip;
        auto value = raw[eq + 1 .. $].strip;
        switch (key) {
          case "main":
            spec.main = value;
            break;
          case "entry":
            spec.entry = value;
            break;
          case "working_dir":
            spec.workingDir = value;
            break;
          case "runtime":
            spec.runtime = value;
            break;
          case "exec":
            spec.exec = value;
            break;
          case "base":
            spec.base = value;
            break;
          case "instance":
            spec.instance = value;
            break;
          case "engine":
            warnings ~= format("line %d: [app] engine 已移除：引擎入口改由 [engine] init"
                ~ " = <路径|命令> 指定（不是 java 类）", i + 1);
            break;
          default:
            warnings ~= format("line %d: unknown [app] key %s", i + 1, key);
        }
        break;
      case "runtime":
        spec.runtimeOptions ~= raw;
        break;
      case "args":
        spec.args ~= raw;
        break;
      case "libs":
        spec.libs ~= raw;
        break;
      case "engine":
        auto eq = raw.indexOf("=");
        auto key = eq < 0 ? "" : raw[0 .. eq].strip;
        if (key == "init") {
          auto value = raw[eq + 1 .. $].strip;
          if (value.length == 0) {
            warnings ~= format("line %d: [engine] init needs a script path", i + 1);
          } else {
            spec.engineInit = value;
          }
        } else {
          spec.engineDeps ~= raw;
        }
        break;
      case "subapp":
        auto eq = raw.indexOf("=");
        if (eq < 0) {
          warnings ~= format("line %d: [subapp %s] expects key = value", i + 1,
              spec.subapps.length ? spec.subapps[$ - 1].id : "");
          continue;
        }
        auto key = raw[0 .. eq].strip;
        auto value = raw[eq + 1 .. $].strip;
        if (spec.subapps.length == 0) {
          continue;
        }
        ref app = spec.subapps[$ - 1];
        switch (key) {
          case "entry":
            app.entry = value;
            break;
          case "path":
            app.path = value;
            break;
          case "libs":
            app.libs ~= value;
            break;
          default:
            warnings ~= format("line %d: unknown [subapp] key %s", i + 1, key);
        }
        break;
      default:
        break;
    }
  }
  return spec;
}

/**
 * 展开 `[subapp <id>] libs` 行：一行可写多个 gav（逗号或分号分隔），也可多行累加。
 * 返回按出现顺序去空白后的 gav 列表，供 jstart 解析取回、并写入交付计划文件。
 */
string[] flattenLibs(string[] libs) {
  string[] gavs;
  foreach (line; libs) {
    foreach (part; line.replace(";", ",").split(",")) {
      auto gav = part.strip;
      if (gav.length > 0) {
        gavs ~= gav;
      }
    }
  }
  return gavs;
}

/// 上下文路径归一化的**预检**副本（去尾 `/`、补首个 `/`、折叠 `//`）；权威公式在引擎侧。
private string normalizeContextPath(string p) {
  auto path = p.strip;
  if (path.length == 0 || path == "/") {
    return "";
  }
  if (!path.startsWith("/")) {
    path = "/" ~ path;
  }
  while (path.length > 1 && path[$ - 1] == '/') {
    path = path[0 .. $ - 1];
  }
  while (path.length > 1) {
    auto folded = path.replace("//", "/");
    if (folded == path) {
      break;
    }
    path = folded;
  }
  return path;
}

/**
 * Cross-key invariants the line parser cannot enforce on its own. Returns an
 * error message, or "" when the spec is consistent.
 *
 * `[app] main` and `[engine]` are mutually exclusive: a jar with a main
 * class is launched directly by java, while an engine target is started by
 * its `[engine] init` script. An [engine] section must always declare an
 * `init` script. `[app] instance`, when given, must be a safe path segment.
 */
string validateLaunchSpec(LaunchSpec spec) {
  if (spec.instance.length > 0 && !isSafeInstanceName(spec.instance)) {
    return format("[app] instance `%s` must be a single safe path segment"
        ~ " ([A-Za-z0-9._-], not `.` or `..`)", spec.instance);
  }
  if (spec.subapps.length > 0) {
    if (spec.entry.length > 0) {
      return "[app] entry conflicts with [subapp <id>] sections: use one form or the other";
    }
    if (spec.main.length > 0) {
      return "[app] main conflicts with [subapp <id>] sections: a subapp is started by the"
          ~ " engine init program, not by a java main class";
    }
    if (spec.libs.length > 0) {
      return "[libs] conflicts with [subapp <id>] sections: each subapp declares its own"
          ~ " extension libs and reads its war's META-INF/beangle/dependencies";
    }
    // 多应用本质是引擎目标：必须显式声明引擎 init 命令，没有缺省。
    if (!spec.hasEngine) {
      return "[subapp <id>] needs an [engine] section: add `[engine]` with"
          ~ " `init = <path|command>`; jstart ships no built-in engine.";
    }
    if (spec.engineInit.length == 0) {
      return "[subapp <id>] needs [engine] init = <path|command>: declare the engine"
          ~ " entry program that starts the container; jstart ships no built-in engine.";
    }
    string[] paths;
    string[] ids;
    foreach (app; spec.subapps) {
      if (app.id.indexOf(' ') >= 0 || app.id.indexOf('\t') >= 0) {
        return format("[subapp] id `%s` cannot contain spaces or tabs", app.id);
      }
      if (ids.canFind(app.id)) {
        return format("duplicate [subapp %s] section", app.id);
      }
      ids ~= app.id;
      if (app.entry.length == 0) {
        return format("[subapp %s] needs an entry", app.id);
      }
      if (app.path.length == 0) {
        return format("[subapp %s] needs a path", app.id);
      }
      auto normalized = normalizeContextPath(app.path);
      if (paths.canFind(normalized)) {
        return format("duplicate context path %s in [subapp <id>] sections", app.path);
      }
      paths ~= normalized;
    }
  }
  // 单应用 engine 目标：声明了 [engine] 段就必须给 init（路径或命令行，不是类）。
  if (spec.hasEngine && spec.engineInit.length == 0) {
    return "[engine] needs an init command: add `init = <path|command>` (the engine"
        ~ " entry program, not a java class).";
  }
  if (spec.main.length == 0) {
    return "";
  }
  if (spec.hasEngine) {
    return "[app] main conflicts with the [engine] section: they are mutually exclusive "
        ~ "(a jar runs its main class directly, an engine target runs its [engine] init program)";
  }
  return "";
}
