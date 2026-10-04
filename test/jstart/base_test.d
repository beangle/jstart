/**
 * Unit tests for jstart.base: component keys and bases, pid file round-trips,
 * stale / recycled pid detection and the SIGTERM/SIGKILL stop path.
 *
 * Test code lives outside of source/, mirroring the beangle micdn layout.
 */
module test.jstart.base_test;

import std.algorithm : canFind, endsWith, startsWith;
import std.conv : to;
import std.file : exists, mkdirRecurse, remove, tempDir;
import std.path : buildPath, dirName;
import std.process : Pid, spawnProcess, thisProcessID, wait;

import jstart.base : PidInfo, baseRootDir, componentKey, currentPid, defaultBase, pidFileName,
  pidFilePath, processAlive, processStartTime, readPidFile, removePidFile, resolveBase,
  isSafeInstanceName, stopApplication, stopNotRunning, stopOk, writePidFile, writePidFileFor;

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

  // 默认 base：<默认根>/<组件键>，目录随之创建；pid 文件固定在 <base>/app.pid
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
    assert(pidFilePath(dflt) == buildPath(dflt, pidFileName));
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

unittest {
  auto tmp = makeTmp();
  scope (exit) rmTree(tmp);
  auto path = buildPath(tmp, "app.pid");

  // 写入携带本进程 pid + start 时间的文件，读回一致
  string err;
  assert(writePidFile(path, "my-target", "/opt/app.jar", err), err);
  PidInfo info;
  assert(readPidFile(path, info));
  assert(info.pid == currentPid());
  assert(info.start.length > 0, "start time should come from /proc/<pid>/stat");
  assert(info.target == "my-target");
  assert(info.app == "/opt/app.jar");

  assert(processAlive(currentPid()));
  assert(!processAlive(999999));

  // 缺 pid= 行的文件视为无效
  auto malformed = buildPath(tmp, "bad.pid");
  import std.file : write;

  write(malformed, "target=x\n");
  assert(!readPidFile(malformed, info));
  assert(stopApplication(malformed, 1, false, false) == stopNotRunning);

  // 消失的 pid：判为“未运行”并清掉残留文件
  auto child = spawnProcess(["sleep", "30"]);
  auto childPid = cast(long) child.processID;
  assert(writePidFileFor(path, childPid, processStartTime(childPid), "sleep", "sleep", err), err);
  import core.sys.posix.signal : SIGKILL, kill;

  kill(cast(int) childPid, SIGKILL);
  wait(child);
  assert(!processAlive(childPid));
  assert(stopApplication(path, 1, false, false) == stopNotRunning);
  assert(!exists(path));
}

unittest {
  // start 时间不匹配（pid 被复用）：不误杀，报“未运行”
  auto tmp = makeTmp();
  scope (exit) rmTree(tmp);
  auto path = buildPath(tmp, "recycled.pid");
  auto child = spawnProcess(["sleep", "30"]);
  auto childPid = cast(long) child.processID;
  string err;
  assert(writePidFileFor(path, childPid, "1", "other", "other", err), err);
  assert(stopApplication(path, 1, false, false) == stopNotRunning);
  assert(processAlive(childPid), "recycled pid must not be signalled");
  restore(child, childPid);
}

/// 清理测试子进程（SIGKILL + wait，避免僵尸/泄漏）。
private void restore(Pid child, long pid) {
  version (Posix) {
    import core.sys.posix.signal : SIGKILL, kill;

    kill(cast(int) pid, SIGKILL);
  }
  wait(child);
}

unittest {
  // stop：SIGTERM 退出（exit 0）；忽略 SIGTERM 时 --force 用 SIGKILL
  version (Posix) {
    auto tmp = makeTmp();
    scope (exit) rmTree(tmp);
    auto path = buildPath(tmp, "stop.pid");
    string err;

    auto normal = spawnProcess(["sleep", "30"]);
    auto normalPid = cast(long) normal.processID;
    assert(writePidFileFor(path, normalPid, processStartTime(normalPid), "sleep", "sleep", err),
        err);
    assert(stopApplication(path, 5, false, false) == stopOk);
    assert(!processAlive(normalPid));
    wait(normal);
    assert(!exists(path));

    // 循环让 shell 无法用 exec 优化掉自己，trap 保证 SIGTERM 被忽略；
    // 就绪文件避免在 trap 生效前就发信号（会误杀）。
    auto ready = buildPath(tmp, "stubborn.ready");
    auto stubborn = spawnProcess(
        ["sh", "-c", "trap '' TERM; touch '" ~ ready ~ "'; while :; do sleep 1; done"]);
    auto stubbornPid = cast(long) stubborn.processID;
    for (auto i = 0; i < 50 && !exists(ready); i++) {
      import core.thread : Thread;
      import core.time : msecs;

      Thread.sleep(100.msecs);
    }
    assert(exists(ready), "stubborn shell did not install its TERM trap");
    assert(writePidFileFor(path, stubbornPid, processStartTime(stubbornPid), "stubborn",
        "stubborn", err), err);
    assert(processAlive(stubbornPid));
    // 不 --force：SIGTERM 无效，超时后报失败且进程仍在
    assert(stopApplication(path, 1, false, false) == 1);
    assert(processAlive(stubbornPid));
    assert(exists(path));
    // --force：超时后 SIGKILL
    assert(stopApplication(path, 1, true, false) == stopOk);
    assert(!processAlive(stubbornPid));
    wait(stubborn);
    assert(!exists(path));
  }
}

unittest {
  // removePidFile 幂等
  auto tmp = makeTmp();
  scope (exit) rmTree(tmp);
  auto path = buildPath(tmp, "x.pid");
  assert(!removePidFile(path));
  import std.file : write;

  write(path, "pid=1\n");
  assert(removePidFile(path));
  assert(!exists(path));
}

unittest {
  // 默认布局：stop 清 pid 文件时连空的 base 目录链一起清（war 会在 base 下留
  // webapps/、native 会留 app/）；base 根本身保留，非空层（应用自留文件）不删
  auto target = "/opt/app/prune-" ~ to!string(thisProcessID) ~ ".war";
  auto base = defaultBase(target);
  if (base.length) {
    import std.file : write;

    auto path = pidFilePath(base);
    auto nested = buildPath(base, "webapps", "ROOT");
    mkdirRecurse(nested);
    write(path, "pid=1\n");
    assert(removePidFile(path));
    assert(!exists(base), "空的 base 目录链应被清理");
    assert(exists(baseRootDir()), "base 根自身不能删");

    mkdirRecurse(nested);
    write(path, "pid=1\n");
    write(buildPath(base, "app.log"), "log\n");
    assert(removePidFile(path));
    assert(!exists(path));
    assert(exists(buildPath(base, "app.log")), "非空层必须保留");
    assert(exists(base), "还有非空内容时 base 保留");
    assert(!exists(buildPath(base, "webapps")), "空的子目录应被清掉");
    rmTree(base);
  }

  // 显式根：组件目录（jstart 建的）照样清理，根目录本身不动
  auto tmp = makeTmp();
  scope (exit) rmTree(tmp);
  import std.file : write;

  auto root = buildPath(tmp, "root");
  auto outside = buildPath(root, "component-a1b2c3d4", pidFileName);
  mkdirRecurse(dirName(outside));
  write(outside, "pid=1\n");
  assert(removePidFile(outside));
  assert(!exists(dirName(outside)), "空的组件目录应被清理");
  assert(exists(root), "base 根不能被清理");
}
