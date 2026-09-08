/**
 * Launch spec files: an ini-like description of how to start an application.
 *
 * A spec declares the main class (Java only), the application entry
 * (gav/http/file/dir), the runtime executable and its options, application
 * args, an optional explicit dependency list and, for war entries, the
 * built-in engine (see docs/war-engine.md), turning `run` into a complete
 * "how to start" description. See docs/launch-spec.md for the format and
 * design decisions.
 */
module jstart.spec;

import std.algorithm : endsWith;
import std.array : split;
import std.format : format;
import std.string : indexOf, startsWith, strip;

/// Launch spec suffix: a spec target must be named <name>.jstart.
immutable string[] specExtensions = [".jstart"];

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
      section = raw[1 .. $ - 1].strip;
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
      default:
        break;
    }
  }
  return spec;
}
