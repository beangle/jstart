/**
 * Built-in war engines and the explode layout they expect.
 *
 * A war cannot be launched by a Main-Class: jstart mirrors beangle/boot's
 * sas.sh, exploding the war under <base>/webapps/<name> and execing the
 * engine bootstrap class with the war classes/libs and the engine jars on
 * the java classpath.
 *
 * Engine selection and jars are declared in the launch spec:
 *
 *   [app]
 *   engine = tomcat            # 可选：war 目标默认 tomcat；jar/其它运行时忽略
 *
 *   [engine]                   # 可选段：引擎依赖，每行与 [deps] 同语法；
 *   org.beangle.sas:beangle-sas-engine:0.13.10
 *   org.apache.tomcat.embed:tomcat-embed-core:11.0.21
 *   org.apache.tomcat.embed:tomcat-embed-websocket:11.0.21
 *
 * When the [engine] section is present its lines are authoritative and no
 * built-in catalog is consulted. Without a spec (or without [engine]) a
 * built-in default catalog (tomcat and undertow, versions pinned like the
 * sas.sh download lines) keeps `jstart run app.war` working out of the
 * box; pinning another version or mirror still goes through [engine].
 */
module jstart.engine;

import std.algorithm : canFind;
import std.array : join, split;
import std.path : buildPath;
import std.process : environment;
import std.string : endsWith, replace, startsWith, strip;

import jstart.archive : Archive, Artifact;

/// Engine names known to jstart with a fixed bootstrap main class.
immutable string[] builtinEngineNames = ["tomcat", "undertow"];

/**
 * Bootstrap main class of an engine: both beangle/sas engines follow
 * org.beangle.sas.engine.<name>.Bootstrap. Throws on unknown names.
 */
string engineMainClass(string name) {
  switch (name) {
    case "tomcat":
      return "org.beangle.sas.engine.tomcat.Bootstrap";
    case "undertow":
      return "org.beangle.sas.engine.undertow.Bootstrap";
    default:
      throw new Exception("Unknown engine " ~ name
          ~ ", built-in engines: " ~ builtinEngineNames.join(", "));
  }
}

/// Engine catalog versions, pinned like the sas.sh export lines.
enum beangleSasVersion = "0.13.10";
enum tomcatEmbedVersion = "11.0.21";
enum undertowVersion = "2.3.24.Final";
enum jbossLoggingVersion = "3.6.1.Final";
enum jbossThreadsVersion = "3.7.0.Final";
enum xnioVersion = "3.8.16.Final";
enum jakartaAnnotationVersion = "2.1.1";
enum wildflyConfigVersion = "1.0.1.Final";
enum wildflyCommonVersion = "1.5.4.Final";
enum smallryeVersion = "2.6.0";

/// A release jar artifact from group:artifact:version.
private Artifact gav(string g, string a, string v) {
  return new Artifact(g ~ ":" ~ a ~ ":" ~ v, g, a, v, "", "jar");
}

/**
 * The engine jar set listed by beangle/boot sas.sh for the tomcat branch:
 * the sas engine plus the two tomcat embed jars.
 */
private Archive[] tomcatCatalog() {
  return [
    gav("org.beangle.sas", "beangle-sas-engine", beangleSasVersion),
    gav("org.apache.tomcat.embed", "tomcat-embed-core", tomcatEmbedVersion),
    gav("org.apache.tomcat.embed", "tomcat-embed-websocket", tomcatEmbedVersion),
  ];
}

/**
 * The engine jar set listed by beangle/boot sas.sh for the undertow
 * branch: the sas engine plus undertow/XNIO/wildfly/smallrye jars.
 */
private Archive[] undertowCatalog() {
  return [
    gav("org.beangle.sas", "beangle-sas-engine", beangleSasVersion),
    gav("io.undertow", "undertow-core", undertowVersion),
    gav("io.undertow", "undertow-servlet", undertowVersion),
    gav("org.jboss.logging", "jboss-logging", jbossLoggingVersion),
    gav("org.jboss.threads", "jboss-threads", jbossThreadsVersion),
    gav("org.jboss.xnio", "xnio-api", xnioVersion),
    gav("org.jboss.xnio", "xnio-nio", xnioVersion),
    gav("jakarta.annotation", "jakarta.annotation-api", jakartaAnnotationVersion),
    gav("org.wildfly.client", "wildfly-client-config", wildflyConfigVersion),
    gav("org.wildfly.common", "wildfly-common", wildflyCommonVersion),
    gav("io.smallrye.common", "smallrye-common-annotation", smallryeVersion),
    gav("io.smallrye.common", "smallrye-common-constraint", smallryeVersion),
    gav("io.smallrye.common", "smallrye-common-cpu", smallryeVersion),
    gav("io.smallrye.common", "smallrye-common-function", smallryeVersion),
  ];
}

/**
 * Default engine jars used when no [engine] section declares them. Both
 * built-in engines mirror the sas.sh download lines; an [engine] section
 * is still the authoritative way to pin other versions or mirrors.
 */
Archive[] defaultEngineDeps(string name) {
  switch (name) {
    case "tomcat":
      return tomcatCatalog();
    case "undertow":
      return undertowCatalog();
    default:
      throw new Exception("Engine " ~ name
          ~ " has no built-in default dependencies: declare them in the [engine] section of the launch spec");
  }
}

/**
 * Context path normalization, equivalent to beangle/sas Server.Config
 * normalizePath ("" or "/" -> ""; else leading '/', no trailing '/',
 * "//" collapsed).
 */
string normalizeContextPath(string p) {
  if (p.length == 0 || p == "/") {
    return "";
  }
  string path = p;
  if (!path.startsWith("/")) {
    path = "/" ~ path;
  }
  while (path.endsWith("/")) {
    path = path[0 .. $ - 1];
  }
  while (path.canFind("//")) {
    path = path.replace("//", "/");
  }
  return path;
}

/**
 * Directory name of an exploded war under <base>/webapps, equivalent to
 * the sas guessDocBase layout: "" or "/" -> ROOT, "/a/b" -> a#b. Returns
 * "" for unsafe names (".", "..") which must not be extracted into.
 */
string warDocBaseName(string contextPath) {
  auto ctx = normalizeContextPath(contextPath);
  if (ctx.length == 0) {
    return "ROOT";
  }
  auto name = ctx[1 .. $].replace("/", "#");
  if (name == "." || name == "..") {
    return "";
  }
  return name;
}

/// Default engine base dir, mirroring sas.sh's /tmp/sas.
string defaultWarBase() {
  auto t = environment.get("TMPDIR");
  if (t.length == 0) {
    t = "/tmp";
  }
  while (t.length > 1 && t[$ - 1] == '/') {
    t = t[0 .. $ - 1];
  }
  return t ~ "/jstart-sas";
}

/**
 * Scan run args for --path=/--base= so the explode location matches what
 * the engine will compute (CmdOptions semantics: the last occurrence
 * wins). Other args such as --port are left untouched for the engine.
 */
void scanEngineArgs(string[] args, ref string path, ref string base) {
  foreach (a; args) {
    if (a.startsWith("--path=")) {
      path = a["--path=".length .. $];
    } else if (a.startsWith("--base=")) {
      base = a["--base=".length .. $].strip;
    }
  }
}

/// Explode destination of a war: <base>/webapps/<name>.
string warDocBaseDir(string base, string name) {
  return buildPath(base, "webapps", name);
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
