/**
 * Which class a java target starts, and where that decision came from.
 *
 * Priority: command line `--main` > launch spec `[app] main` > the entry's
 * `META-INF/MANIFEST.MF` `Main-Class`. The policy is pure string handling, so
 * run/classpath/info all share it and it is unit-testable without a jar.
 *
 * A main class is only meaningful for java targets (jar / exploded dir / gav
 * resolving to either). A war runs the engine's bootstrap class and a native
 * (tar.gz) distribution runs `[app] exec`, so an override given for those is
 * ignored with a warning instead of failing the run.
 */
module jstart.mainclass;

import std.string : strip;

/// Where the effective main class came from.
enum MainSource {
  /// No main class anywhere.
  none,
  /// Command line --main.
  cli,
  /// Launch spec [app] main.
  spec,
  /// The entry's MANIFEST.MF Main-Class.
  manifest,
}

/// Effective main class plus its source.
struct MainClass {
  /// Fully qualified class name ("" when unknown).
  string name;
  /// Where `name` came from.
  MainSource source = MainSource.none;

  /// Whether a main class is known.
  bool empty() const {
    return name.length == 0;
  }
}

/**
 * Pick the effective main class: `--main` > `[app] main` > manifest. Empty
 * (or blank) values fall through to the next source; a blank `--main` is
 * rejected earlier by the caller, so it never silently becomes "not given".
 */
MainClass pickMainClass(string cliMain, string specMain, string manifestMain) {
  auto fromCli = cliMain.strip;
  if (fromCli.length) {
    return MainClass(fromCli, MainSource.cli);
  }
  auto fromSpec = specMain.strip;
  if (fromSpec.length) {
    return MainClass(fromSpec, MainSource.spec);
  }
  auto fromManifest = manifestMain.strip;
  if (fromManifest.length) {
    return MainClass(fromManifest, MainSource.manifest);
  }
  return MainClass.init;
}

/// Stable name of a source, for logs and `info` output: cli/spec/manifest/none.
string sourceName(MainSource source) {
  final switch (source) {
    case MainSource.none:
      return "none";
    case MainSource.cli:
      return "cli";
    case MainSource.spec:
      return "spec";
    case MainSource.manifest:
      return "manifest";
  }
}

/**
 * Whether a value is a plausible java main class name: a dotted sequence of
 * java identifiers (letters/digits/_/$, `$` for nested classes). This rejects
 * paths, urls and stray whitespace, so `--main=/path/App.java` fails fast with
 * a hint instead of turning into a puzzling JVM error. Whether the class
 * actually exists is left to the JVM (it depends on the whole classpath).
 */
bool isPlausibleMainClass(string name) {
  auto s = name.strip;
  if (s.length == 0) {
    return false;
  }
  bool expectStart = true; // 每段必须以标识符首字符开头（不能是数字）
  foreach (c; s) {
    if (c == '.') {
      if (expectStart) {
        return false; // 空段：.Foo / Foo. / Foo..Bar
      }
      expectStart = true;
      continue;
    }
    if (c == '_' || c == '$' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
      expectStart = false;
    } else if (c >= '0' && c <= '9') {
      if (expectStart) {
        return false; // 段首不能是数字
      }
    } else {
      return false; // 空白、'/'、':'、'-' 等都不是主类名
    }
  }
  return !expectStart;
}
