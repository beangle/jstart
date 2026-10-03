/**
 * War engine selection and the "engine entry main" protocol.
 *
 * A war cannot be launched by a Main-Class: jstart hands the war (a war
 * file or an already-exploded directory) to an **engine entry main**, a
 * small program that prepares the container environment, writes the final
 * launch command to a file and exits. jstart then execs that command. The
 * war is therefore no longer exploded by jstart - the engine owns the
 * docBase layout and the explosion, so the layout formula lives in exactly
 * one place (beangle/sas). See docs/engine.md for the full protocol.
 *
 * Engine selection and jars are declared in the launch spec:
 *
 *   [app]
 *   engine = tomcat                # 内置别名：tomcat|undertow（war 缺省 tomcat）
 *   engine = tomcat-11.0.24        # 内置别名可带 tomcat 版本后缀
 *   engine = org.example.MyMain    # 含 "." 的值直接作为入口 main 的 FQCN
 *
 *   [engine]                       # 可选段：引擎依赖，每行与 [deps] 同语法；
 *   org.beangle.sas:beangle-sas-engine:0.13.17
 *   org.apache.tomcat.embed:tomcat-embed-core:11.0.21
 *   org.apache.tomcat.embed:tomcat-embed-websocket:11.0.21
 *   # 行内可用占位符引用内置版本：
 *   #   {tomcat.version}  tomcat 版本（engine = tomcat-<版本> 时用该版本，否则内置默认）
 *   #   {sas.version}     beangle-sas-engine 内置默认版本
 *
 * When the [engine] section is present its lines are authoritative and no
 * built-in catalog is consulted. Without [engine] the built-in catalog
 * (tomcat and undertow, versions pinned like the sas.sh download lines)
 * keeps `jstart run app.jstart` working out of the box; a custom entry main
 * (an FQCN value) has no built-in catalog and must declare its jars in
 * [engine].
 */
module jstart.engine;

import std.algorithm : canFind, endsWith;
import std.array : join, split;
import std.string : indexOf, replace, strip;

import jstart.archive : Archive, Artifact;

/// Built-in engine aliases: values without '.' that map to a known entry main.
immutable string[] builtinEngineNames = ["tomcat", "undertow"];

/// 全量 tomcat（发行包）入口 main：多 webapp 的 Dist 模式，也是多应用 spec 的缺省引擎。
immutable string distTomcatEntryMain = "org.beangle.sas.engine.tomcat.ServerCreator";

/**
 * 是否是内嵌（单 webapp）引擎入口 main。多应用 spec 必须走 Dist 模式，内嵌引擎
 * 只跑一个 webapp；[app] engine 写成内嵌 FQCN 时按此拒绝。
 *
 * 0.13.17 把内嵌入口从 `*EmbedMain` 改名为 `*EmbedCreator`，旧名继续按内嵌识别，
 * 使指向旧引擎 jar 的 spec 不会被误判成 Dist（全量容器）模式。
 */
bool isEmbedEntryMain(string entryMain) {
  return entryMain.endsWith(".EmbedCreator") || entryMain.endsWith(".EmbedMain");
}

private string unknownEngineMsg(string name) {
  return "Unknown engine " ~ name
      ~ ", built-in engines: " ~ builtinEngineNames.join(", ")
      ~ "; to run another engine give its entry main class (a value containing '.')";
}

/**
 * Entry main class of a built-in engine alias. Both beangle/sas engines
 * expose the embedded-container entry as
 * org.beangle.sas.engine.<name>.EmbedCreator; the full tomcat distribution is
 * a separate main (ServerCreator) selected by writing its FQCN as the engine
 * value. Throws on unknown aliases.
 */
string engineEntryMain(string aliasName) {
  switch (aliasName) {
    case "tomcat":
      return "org.beangle.sas.engine.tomcat.EmbedCreator";
    case "undertow":
      return "org.beangle.sas.engine.undertow.EmbedCreator";
    default:
      throw new Exception(unknownEngineMsg(aliasName));
  }
}

/// A parsed [app] engine selection.
struct EngineSel {
  /// Entry main class: the FQCN the engine main is started with.
  string entryMain;
  /// Built-in alias name (tomcat/undertow), or "" when the value was an FQCN.
  string aliasName;
  /// Version requested via <alias>-<ver>; "" selects the built-in default.
  string ver;
}

/**
 * Parse an [app] engine value:
 *
 *  - a value containing '.' is a fully-qualified entry main class and is
 *    used as-is (alias/ver empty; no built-in dependency catalog);
 *  - otherwise it is a built-in alias, optionally with a version suffix
 *    ("tomcat", "tomcat-11.0.24", "undertow"). Only tomcat carries a
 *    version suffix: it re-pins the built-in catalog's tomcat-embed jars
 *    and {tomcat.version} placeholders. Unknown aliases throw here.
 */
EngineSel parseEngineSel(string sel) {
  EngineSel r;
  auto dash = sel.indexOf("-");
  auto head = dash < 0 ? sel : sel[0 .. dash];
  // 先看别名：tomcat-11.0.24 也含 "."，不能先按 FQCN 判。
  if (builtinEngineNames.canFind(head)) {
    r.aliasName = head;
    if (dash >= 0) {
      r.ver = sel[dash + 1 .. $];
    }
    if (r.ver.length > 0 && r.aliasName != "tomcat") {
      throw new Exception("Engine " ~ sel
          ~ ": version suffix is only supported for tomcat (e.g. tomcat-11.0.24);"
          ~ " pin " ~ r.aliasName ~ " jars in the [engine] section instead");
    }
    r.entryMain = engineEntryMain(r.aliasName);
    return r;
  }
  if (sel.indexOf(".") >= 0) {
    r.entryMain = sel;
    return r;
  }
  throw new Exception(unknownEngineMsg(sel));
}

/// Engine catalog versions, pinned like the sas.sh export lines.
/// beangle-sas-engine 必须含引擎入口 main（EmbedCreator/ServerCreator，0.13.17 起）；
/// 更早的 EmbedMain/DistMain 已被取代，仅 EmbedMain 作为内嵌旧名继续被识别。
enum beangleSasVersion = "0.13.17";
enum tomcatEmbedVersion = "11.0.21";
enum undertowVersion = "2.4.4.Final";
enum undertowEeVersion = "2.0.2.Final";
enum jbossLoggingVersion = "3.6.3.Final";
enum jbossThreadsVersion = "3.9.2";
enum xnioVersion = "3.8.16.Final";
enum jakartaAnnotationVersion = "2.1.1";
enum jakartaServletVersion = "6.1.0";
enum jakartaWebsocketVersion = "2.2.0";
enum wildflyConfigVersion = "1.0.1.Final";
enum wildflyCommonVersion = "2.0.1";
enum smallryeVersion = "2.14.0";

/// A release jar artifact from group:artifact:version.
private Artifact gav(string g, string a, string v) {
  return new Artifact(g ~ ":" ~ a ~ ":" ~ v, g, a, v, "", "jar");
}

/// 非 jar 打包（如 tomcat 发行包 zip）的 gav 构件。
private Artifact gavp(string g, string a, string v, string packaging) {
  return new Artifact(g ~ ":" ~ a ~ ":" ~ packaging ~ ":" ~ v, g, a, v, "", packaging);
}

/**
 * The engine jar set listed by beangle/boot sas.sh for the tomcat branch:
 * the sas engine plus the two tomcat embed jars. The embed jars use the
 * requested tomcat version or, when empty, the built-in default.
 */
private Archive[] tomcatCatalog(string ver) {
  auto v = ver.length > 0 ? ver : tomcatEmbedVersion;
  return [
    gav("org.beangle.sas", "beangle-sas-engine", beangleSasVersion),
    gav("org.apache.tomcat.embed", "tomcat-embed-core", v),
    gav("org.apache.tomcat.embed", "tomcat-embed-websocket", v),
  ];
}

/**
 * The engine jar set listed by beangle/boot sas.sh for the undertow
 * branch: the sas engine plus undertow(EE10)/servlet/websocket API/XNIO/
 * wildfly/smallrye jars. undertow-servlet moved to the io.undertow.ee
 * coordinates for the Jakarta EE 10 split, and the servlet/websocket APIs
 * come from jakarta.* rather than the container.
 */
private Archive[] undertowCatalog() {
  return [
    gav("org.beangle.sas", "beangle-sas-engine", beangleSasVersion),
    gav("io.undertow", "undertow-core", undertowVersion),
    gav("io.undertow.ee", "undertow-servlet", undertowEeVersion),
    gav("io.undertow.ee", "undertow-websockets", undertowEeVersion),
    gav("org.jboss.logging", "jboss-logging", jbossLoggingVersion),
    gav("org.jboss.threads", "jboss-threads", jbossThreadsVersion),
    gav("org.jboss.xnio", "xnio-api", xnioVersion),
    gav("org.jboss.xnio", "xnio-nio", xnioVersion),
    gav("jakarta.annotation", "jakarta.annotation-api", jakartaAnnotationVersion),
    gav("jakarta.servlet", "jakarta.servlet-api", jakartaServletVersion),
    gav("jakarta.websocket", "jakarta.websocket-api", jakartaWebsocketVersion),
    gav("jakarta.websocket", "jakarta.websocket-client-api", jakartaWebsocketVersion),
    gav("org.wildfly.client", "wildfly-client-config", wildflyConfigVersion),
    gav("org.wildfly.common", "wildfly-common", wildflyCommonVersion),
    gav("io.smallrye.common", "smallrye-common-annotation", smallryeVersion),
    gav("io.smallrye.common", "smallrye-common-constraint", smallryeVersion),
    gav("io.smallrye.common", "smallrye-common-cpu", smallryeVersion),
    gav("io.smallrye.common", "smallrye-common-expression", smallryeVersion),
    gav("io.smallrye.common", "smallrye-common-function", smallryeVersion),
    gav("io.smallrye.common", "smallrye-common-net", smallryeVersion),
    gav("io.smallrye.common", "smallrye-common-os", smallryeVersion),
    gav("io.smallrye.common", "smallrye-common-ref", smallryeVersion),
  ];
}

/**
 * Dist（全量 tomcat）模式下 jstart 侧的内置引擎目录：beangle-sas-engine（含
 * ServerCreator/EngineCreator）加一份 tomcat 发行包 zip（ServerCreator 在 classpath 上取
 * 第一个 .zip 解压到 <base>/engines/）。发行包里已含容器 jar，无需 embed 目录。
 */
private Archive[] distTomcatCatalog(string ver) {
  auto v = ver.length > 0 ? ver : tomcatEmbedVersion;
  return [
    gav("org.beangle.sas", "beangle-sas-engine", beangleSasVersion),
    gavp("org.apache.tomcat", "tomcat", v, "zip"),
  ];
}

/**
 * Default engine jars used when no [engine] section declares them. Both
 * built-in engines mirror the sas.sh download lines; an [engine] section
 * is still the authoritative way to pin other versions or mirrors.
 *
 * For tomcat the caller passes the version of an engine = tomcat-<version>
 * selection; "" keeps the built-in default. Undertow takes no version.
 */
Archive[] defaultEngineDeps(string name, string ver = "") {
  switch (name) {
    case "tomcat":
      return tomcatCatalog(ver);
    case "undertow":
      if (ver.length > 0) {
        throw new Exception("Engine " ~ name ~ "-" ~ ver
            ~ ": version suffix is only supported for tomcat (e.g. tomcat-11.0.24);"
            ~ " pin undertow jars in the [engine] section instead");
      }
      return undertowCatalog();
    default:
      throw new Exception("Engine " ~ name
          ~ " has no built-in default dependencies: declare them in the [engine] section of the launch spec");
  }
}

/**
 * Dist 模式的缺省引擎依赖（无 [engine] 段时）。仅 ServerCreator 有内置目录：beangle-sas-engine
 * 加 tomcat 发行包 zip；其它 dist 入口 main 需要显式 [engine] 段（同 FQCN 规则）。
 */
Archive[] defaultDistEngineDeps(string ver = "") {
  return distTomcatCatalog(ver);
}

/**
 * Expand engine version placeholders in one [engine] dependency line
 * before it is parsed as a gav/path/url:
 *
 *   {tomcat.version}  tomcat embed 版本：engine = tomcat-<版本> 时用该版本，
 *                     否则内置默认版本（tomcatEmbedVersion）；
 *   {sas.version}     beangle-sas-engine 内置默认版本（beangleSasVersion）。
 *
 * Lines without placeholders are returned unchanged.
 */
string expandEngineDeps(string line, string tomcatVer = "") {
  auto v = tomcatVer.length > 0 ? tomcatVer : tomcatEmbedVersion;
  return line.replace("{tomcat.version}", v).replace("{sas.version}", beangleSasVersion);
}

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

/// File under the component base where an engine entry main writes the final argv.
immutable string entryArgvFile = "engine-entry.argv";

/// File under the component base holding the application dependency classpath.
/// The classpath can be very long, so it is handed to the engine entry main via
/// --app-classpath-file instead of on the command line.
immutable string entryClasspathFile = "engine-app.classpath";

/**
 * File under the component base describing the webapps an engine must deploy
 * (multi-webapp specs). One row per webapp, tab separated:
 *
 *   <id> \t <entry path> \t <context path>
 *
 * The entry path is a local war file or an already exploded directory; the
 * context path is the spec's `[webapp <id>] path` value (the engine normalizes
 * it). The engine entry main reads it from `--webapps-file=`.
 */
immutable string webappsPlanFile = "engine-webapps.tsv";

/**
 * Parse the NUL-separated argv an engine entry main wrote to its
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
