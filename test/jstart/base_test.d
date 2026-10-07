/**
 * Unit tests for jstart.base: component keys and the component base
 * directory (creation, privacy, explicit roots and [app] instance names).
 *
 * Test code lives outside of source/, mirroring the beangle micdn layout.
 */
module test.jstart.base_test;

import std.algorithm : canFind, startsWith;
import std.conv : to;
import std.file : exists, mkdirRecurse, remove, tempDir;
import std.path : buildPath;
import std.process : thisProcessID;

import jstart.base : baseRootDir, componentKey, defaultBase, isSafeInstanceName, resolveBase;

private void rmTree(string path) {
  import std.file : dirEntries, SpanMode;

  if (!exists(path)) {
    return;
  }
  foreach (e; dirEntries(path, SpanMode.depth)) {
    remove(e.name);
  }
  if (exists(path)) {
    remove(path);
  }
}

private string makeTmp() {
  auto tmp = buildPath(tempDir(), "jstart-base-test-" ~ to!string(thisProcessID));
  rmTree(tmp);
  mkdirRecurse(tmp);
  return tmp;
}

unittest {
  // 组件键 = 可做文件名的短名 + 目标指纹：同一 target 稳定，不同 target 不同
  auto k = componentKey("/opt/app/app.war");
  assert(k.startsWith("app.war-"), k);
  assert(k.length == "app.war-".length + 8);
  assert(componentKey("./app.war") == componentKey("./app.war"));
  assert(componentKey("/opt/app/app.war") != componentKey("/opt/other/app.war"));
  assert(componentKey("org.beangle:demo:1.0") != componentKey("org.beangle:demo:2.0"));
  // 键总是安全的文件名（无路径分隔符/冒号等）
  auto gav = componentKey("org.beangle:demo:tar.gz:linux-amd64:1.0");
  assert(!gav.canFind(":") && !gav.canFind("/"));

  // 参数不参与身份：同一个 target 永远同一个 base
  assert(componentKey("/opt/app/app.war") == componentKey("/opt/app/app.war"));

  // instance 是显式的安全路径段：只允许 [A-Za-z0-9._-]，拒绝 . / .. / 分隔符 / 空格
  assert(isSafeInstanceName("portal-a"));
  assert(isSafeInstanceName("platform.server1"));
  assert(!isSafeInstanceName(""));
  assert(!isSafeInstanceName("."));
  assert(!isSafeInstanceName(".."));
  assert(!isSafeInstanceName("a/b"));
  assert(!isSafeInstanceName("a b"));
  assert(!isSafeInstanceName("a:b"));

  // 默认 base：<默认根>/<组件键>，目录随之创建
  auto dflt = defaultBase("app.war");
  if (dflt.length) {
    auto otherBase = defaultBase("other.war");
    scope (exit) {
      rmTree(dflt);
      rmTree(otherBase);
    }
    assert(dflt == buildPath(baseRootDir(), componentKey("app.war")), dflt);
    assert(dflt.canFind("app.war-"), dflt);
    assert(exists(dflt));
    assert(otherBase != dflt);
    // 组件目录是私有的（0700，属主本人），根目录可以是共享的
    assert(isPrivateDir(dflt), dflt ~ " should be a 0700 directory");
  }
  // 显式 --base 是根目录：替换 /var/tmp/jstart，组件目录建在其下
  // （~ 由 expandLocalPath 展开，相对路径相对 cwd）
  auto tmp = makeTmp();
  scope (exit) rmTree(tmp);
  auto customRoot = buildPath(tmp, "custom");
  auto customBase = resolveBase("app.war", customRoot);
  assert(customBase == buildPath(customRoot, componentKey("app.war")), customBase);
  assert(exists(customBase));
  assert(isPrivateDir(customBase), customBase ~ " should be a 0700 directory");
  // 根目录缺失时自动创建；同一个根下不同组件互不干扰
  assert(exists(customRoot));
  // [app] instance：组件目录就是 <根>/<名字>，不再拼接目标指纹
  auto customNamed = resolveBase("app.war", customRoot, "portal-a");
  assert(customNamed == buildPath(customRoot, "portal-a"), customNamed);
  assert(customNamed != customBase);
  assert(isPrivateDir(customNamed), customNamed ~ " should be a 0700 directory");
  // 非法 instance 不落到根目录之外
  assert(resolveBase("app.war", customRoot, "../escape") == "");
  assert(resolveBase("app.war", customRoot, "a/b") == "");
  // 根目录不强制 0700（不同用户/组件可以共用），只有组件目录必须私有
  auto sharedRoot = buildPath(tmp, "shared");
  mkdirRecurse(sharedRoot);
  assert(resolveBase("app.war", sharedRoot).startsWith(sharedRoot));
}

/// 目录是否为 0700 且属于当前用户（与 jstart.base 的私有目录约定一致）。
private bool isPrivateDir(string dir) {
  version (Posix) {
    import core.sys.posix.sys.stat : S_IFDIR, S_IFMT, stat, stat_t;
    import core.sys.posix.unistd : getuid;
    import std.conv : octal;
    import std.string : toStringz;

    stat_t st;
    if (stat(dir.toStringz, &st) != 0 || (st.st_mode & S_IFMT) != S_IFDIR
        || st.st_uid != getuid()) {
      return false;
    }
    return (st.st_mode & octal!777) == octal!700;
  } else {
    return true;
  }
}
