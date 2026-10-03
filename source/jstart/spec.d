/**
 * Launch spec files: an ini-like description of how to start an application.
 *
 * A spec declares the main class (Java only), the application entry
 * (gav/http/file/dir), the runtime executable and its options, application
 * args, an optional explicit dependency list and, for war entries, the
 * built-in engine (see docs/war-engine.md), turning `run` into a complete
 * "how to start" description. A spec may instead declare several
 * `[subapp <id>]` sections (entry + context path) so one dist engine runs
 * several webapps in one JVM (see docs/engine.md). See docs/launch-spec.md
 * for the format and design decisions.
 */
module jstart.spec;

import std.algorithm : canFind, endsWith;
import std.array : split;
import std.format : format;
import std.string : indexOf, replace, startsWith, strip;

import jstart.engine : builtinEngineNames, distTomcatEntryMain, isEmbedEntryMain;

/// Launch spec suffix: a spec target must be named <name>.jstart.
immutable string[] specExtensions = [".jstart"];

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
  /// Runtime options, in order (each spec line is one option; java -X/-D,
  /// python -O, ...).
  string[] runtimeOptions;
  /// Application args, in order (each spec line is one argv, no splitting).
  string[] args;
  /// Explicit dependency lines, valid only when hasDeps is true.
  string[] deps;
  /// Whether an explicit [deps] section was present (even when empty).
  bool hasDeps;
  /// Engine selection ([app] engine), meaningful only for war entries.
  /// Empty defaults to "tomcat" at run time; jar/other targets ignore it.
  string engine;
  /// Engine dependency lines ([engine] section), same syntax as deps.
  string[] engineDeps;
  /// Whether an [engine] section was present (even when empty); when
  /// present its lines are authoritative and no built-in catalog is used.
  bool hasEngineDeps;
  /// 多应用：[subapp <id>] 段逐个声明，空表示单应用 spec（[app] entry）。
  SubappSpec[] subapps;
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
        spec.hasDeps = true; // 空 [deps] 段也是"显式无依赖"的声明
      } else if (section == "engine") {
        spec.hasEngineDeps = true; // [engine] 段存在即为准
      } else if (section != "app" && section != "runtime" && section != "args") {
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
          case "engine":
            spec.engine = value;
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
      case "deps":
        spec.deps ~= raw;
        break;
      case "engine":
        spec.engineDeps ~= raw;
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
 * `[app] main` and `[app] engine` are mutually exclusive: a jar with a main
 * class is launched directly by java, while a war's application entry is the
 * engine's entry main. An [engine] dependency section only applies together
 * with an engine, so it conflicts with [app] main too.
 */
string validateLaunchSpec(LaunchSpec spec) {
  if (spec.subapps.length > 0) {
    if (spec.entry.length > 0) {
      return "[app] entry conflicts with [subapp <id>] sections: use one form or the other";
    }
    if (spec.main.length > 0) {
      return "[app] main conflicts with [subapp <id>] sections: a subapp runs an engine entry main";
    }
    if (spec.hasDeps) {
      return "[deps] conflicts with [subapp <id>] sections: each subapp declares its own"
          ~ " dependencies in its war (META-INF/beangle/dependencies)";
    }
    if (spec.engine.length > 0) {
      auto head = spec.engine;
      auto dash = head.indexOf("-");
      if (dash >= 0) {
        head = head[0 .. dash];
      }
      if (builtinEngineNames.canFind(head)) {
        return format("[app] engine = %s is the embedded (single-webapp) engine, but"
            ~ " [subapp <id>] needs the dist engine, which runs several contexts in one JVM;"
            ~ " drop [app] engine or give the dist entry main", spec.engine);
      }
      if (isEmbedEntryMain(spec.engine)) {
        return format("[app] engine = %s is an embedded (single-webapp) entry main, but"
            ~ " [subapp <id>] needs the dist engine, which runs several contexts in one JVM"
            ~ " (e.g. %s)", spec.engine, distTomcatEntryMain);
      }
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
  if (spec.main.length == 0) {
    return "";
  }
  if (spec.engine.length > 0) {
    return "[app] main conflicts with [app] engine: they are mutually exclusive "
        ~ "(a jar runs its main class directly, a war runs an engine entry main)";
  }
  if (spec.hasEngineDeps) {
    return "[app] main conflicts with the [engine] section: they are mutually exclusive "
        ~ "(engine dependencies only apply to war/directory targets)";
  }
  return "";
}
