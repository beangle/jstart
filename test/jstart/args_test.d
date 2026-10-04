/**
 * Unit tests for app.parseArgs: the CLI surface (commands, boolean flags,
 * key=value options, and the target/rest split).
 *
 * The flags exercised here are the ones a caller relies on for scripting:
 * the --verbose/--quiet output pair (default is quiet), the SNAPSHOT-only
 * --snapshot-remote, --main (an empty value must be remembered, not treated
 * as "not given"), and the numeric options that clamp instead of failing.
 *
 * Test code lives outside of source/, mirroring the beangle micdn layout.
 */
module test.jstart.args_test;

import app : parseArgs;

unittest {
  // 默认：run、安静、10 并发、stop 等 15 秒、未给 --main
  auto d = parseArgs([]);
  assert(d.command == "run" && d.target.length == 0 && d.rest.length == 0);
  assert(!d.verbose && !d.quiet && !d.offline && !d.force && !d.print);
  assert(d.jobs == 10 && d.stopTimeout == 15);
  assert(!d.hasMain && d.mainClass.length == 0);
}

unittest {
  // --verbose/-v 与 --quiet/-q 各自独立置位（同给时由 showProgress 决定以 quiet 为准）
  assert(parseArgs(["--verbose"]).verbose);
  assert(parseArgs(["-v"]).verbose);
  assert(parseArgs(["--quiet"]).quiet);
  assert(parseArgs(["-q"]).quiet);
  auto both = parseArgs(["--verbose", "--quiet"]);
  assert(both.verbose && both.quiet);

  assert(parseArgs(["--offline"]).offline);
  assert(parseArgs(["--force"]).force);
  assert(parseArgs(["--print"]).print);
  assert(parseArgs(["--help"]).help);
  assert(parseArgs(["--version"]).showVersion);
  assert(parseArgs(["-V"]).showVersion);
}

unittest {
  // 带值选项：原样取值，空值也保留（--main 由 hasMain 区分"没给"）
  auto o = parseArgs(["--local=/l", "--remote=http://r1,http://r2",
      "--snapshot-remote=http://s1", "--source=/s", "--from=1.0",
      "--base=/b", "--main=com.example.Main",
      "--jobs=4", "--timeout=30"]);
  assert(o.local == "/l");
  assert(o.remote == "http://r1,http://r2");
  assert(o.snapshotRemote == "http://s1");
  assert(o.source == "/s");
  assert(o.from == "1.0");
  assert(o.base == "/b");
  assert(o.mainClass == "com.example.Main" && o.hasMain);
  assert(o.jobs == 4 && o.stopTimeout == 30);

  auto blank = parseArgs(["--main="]);
  assert(blank.hasMain && blank.mainClass.length == 0);

  // 数字选项非法/非正时钳到最小可用值，不报错
  assert(parseArgs(["--jobs=0"]).jobs == 1);
  assert(parseArgs(["--jobs=x"]).jobs == 1);
  assert(parseArgs(["--timeout=0"]).stopTimeout == 1);
  assert(parseArgs(["--timeout=-3"]).stopTimeout == 1);
}

unittest {
  // 子命令只在 target 之前识别；target 之后的裸参数进 rest 原样透传
  foreach (cmd; ["run", "resolve", "classpath", "info", "repo", "fetch", "stop"]) {
    auto p = parseArgs([cmd]);
    assert(p.command == cmd && p.target.length == 0);
  }

  auto r = parseArgs(["resolve", "g:a:v"]);
  assert(r.command == "resolve" && r.target == "g:a:v" && r.rest.length == 0);

  auto run = parseArgs(["run", "app.jar", "extra", "--port=8080"]);
  assert(run.command == "run" && run.target == "app.jar");
  assert(run.rest == ["extra", "--port=8080"]);

  // 选项在 target 之后仍被消费；未识别的参数留到 rest
  auto mixed = parseArgs(["app.jar", "--verbose", "--unknown"]);
  assert(mixed.command == "run" && mixed.target == "app.jar");
  assert(mixed.verbose && mixed.rest == ["--unknown"]);

  // 默认命令 run、目标可省略子命令
  auto bare = parseArgs(["app.jar"]);
  assert(bare.command == "run" && bare.target == "app.jar");
}
