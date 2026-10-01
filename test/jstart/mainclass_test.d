/**
 * Unit tests for jstart.mainclass: main class precedence (--main > [app] main >
 * MANIFEST.MF Main-Class) and the syntax check that keeps paths/urls out.
 *
 * Test code lives outside of source/, mirroring the beangle micdn layout.
 */
module test.jstart.mainclass_test;

import jstart.mainclass : MainSource, isPlausibleMainClass, pickMainClass, sourceName;

unittest {
  // 优先级：命令行 > spec > manifest
  auto m = pickMainClass("cli.Main", "spec.Main", "manifest.Main");
  assert(m.name == "cli.Main" && m.source == MainSource.cli);
  m = pickMainClass("", "spec.Main", "manifest.Main");
  assert(m.name == "spec.Main" && m.source == MainSource.spec);
  m = pickMainClass("", "", "manifest.Main");
  assert(m.name == "manifest.Main" && m.source == MainSource.manifest);
  m = pickMainClass("", "", "");
  assert(m.empty && m.source == MainSource.none);

  // 空白等同于没给（--main= 的空值由命令行的 hasMain 单独报错）
  m = pickMainClass("  ", " spec.Main ", "  ");
  assert(m.name == "spec.Main" && m.source == MainSource.spec);
  m = pickMainClass(" cli.Main ", "", "");
  assert(m.name == "cli.Main" && m.source == MainSource.cli);

  assert(sourceName(MainSource.cli) == "cli");
  assert(sourceName(MainSource.spec) == "spec");
  assert(sourceName(MainSource.manifest) == "manifest");
  assert(sourceName(MainSource.none) == "none");
}

unittest {
  // 合法：点分标识符，允许 $（嵌套类）与数字（非段首）
  foreach (ok; ["Main", "com.example.Main", "com.example.Outer$Inner", "a1.B2",
      "_Hidden.Main", "com.example.Main2"]) {
    assert(isPlausibleMainClass(ok), ok);
  }
  // 非法：空/空白、路径、url、空段、段首数字、其它字符
  // （语法上 App.java 是"App 包里的 java 类"，能通过；但它跑不起来，交给 JVM 报错）
  foreach (bad; ["", "   ", "/path/App.java", "com/example/Main", "com..Main",
      ".Main", "Main.", "1Main", "com.exa mple.Main", "Main;", "a-b.C", "com,example.Main"]) {
    assert(!isPlausibleMainClass(bad), bad);
  }
  // 首尾空白先 strip，再判断
  assert(isPlausibleMainClass("  com.example.Main  "));
}
