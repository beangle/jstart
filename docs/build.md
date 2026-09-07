# 构建、测试与打包

## 环境要求

- 构建机：D 工具链（dub ≥1.34 + ldc2/dmd，推荐 ldc2），`strip`（打包用）。
- 运行机：`curl` 命令（所有下载走宿主 curl，不链接 libcurl）；`run` jar 时还需
  `java`（`JAVA_HOME` 或 PATH）。

工程零 dub 第三方依赖（纯 Phobos + libcurl-free）。

## 构建

```bash
dub build -b release --compiler=ldc2   # 产物 target/jstart（约 470KB）
dub build --build=release-nobounds --compiler=ldc2   # 打包脚本所用（去边界检查）
dub test --compiler=ldc2               # 单元测试（unittest 配置），产物 target/jstart
```

`dub.json` 约定：

- `name`: jstart，`version`: 0.0.1，`targetName`: jstart；
- `targetPath`: target → 所有产物进 `target/`（与 micdn 布局一致）。
- 配置：`application`（默认 release 构建）与 `unittest`（`sourcePaths`/`importPaths`
  含 `source` 与 `test`，供 `dub test` 自动采用，仿 micdn）。

## 单元测试

单元测试独立放在 `test/jstart/`，每个被测模块对应一个 `*_test.d`
（`module test.jstart.*_test`，仿 micdn 布局），`dub test` 按 `unittest` 配置
全量运行；源码 `source/` 不携带任何 `unittest` 块，release 产物不含测试代码。

| 模块 | 覆盖 |
|------|------|
| `test/jstart/archive_test.d` | gav 3/4/5 段解析、classifier/打包类型识别、Maven2 布局、依赖行解析 |
| `test/jstart/repo_test.d` | 本地仓库展开、sha1 文本解析、远程列表（Central 恒在末尾） |
| `test/jstart/zipfile_test.d` | jar/war 条目读取、Manifest `Main-Class` 解析、爆炸解压（嵌套/目录条目/zip-slip 穿越条目跳过） |
| `test/jstart/resolver_test.d` | jar/war/解压目录/文本文件的依赖解析、去重、空行、无描述 jar、dependencyPath（快照时间戳路径） |
| `test/jstart/consolidate_test.d` | repo 整合：复制 jar+sha1、本地已有跳过、双缺失报告 |
| `test/jstart/download_test.d` | 并行下载（--jobs 并发/串行可观测）与 Range 分段下载合并、内容校验 |
| `test/jstart/spec_test.d` | launch spec 识别/完整解析（含 [app] runtime/engine 与旧 java/[jvm] 告警）、行号告警、未知段、deps/engine 段原样保留等 |
| `test/jstart/engine_test.d` | 引擎主类映射、tomcat 内置默认依赖、上下文路径/爆炸目录推导、--path/--base 扫描、引擎依赖去重合并 |

## 冒烟测试

`test/smoke.sh` 端到端验证（需要 `curl`、`zip`，`javac`/`java` 可选但推荐）：

- 现场构造瘦 jar（含依赖描述与 Manifest）；
- resolve：真实下载 `org.slf4j:slf4j-api:2.0.17`；
- classpath：输出含 `Main-Class@` 与依赖路径；
- 二次 resolve：本地缓存命中（无网络请求）；
- run：参数（`--port=8080`、普通参数）透传并 exec 成功；
- gav 目标 resolve；
- war 引擎：真实下载 tomcat 三件套，`run --print` 输出 Bootstrap 命令、验证
  `<base>/webapps/<ctx>` 爆炸布局与参数透传；
- 真实组件运行测试（可选，联网+大下载+java 17+）：`bash test/war-run-test.sh`
  用 `org.beangle.otk:beangle-otk-ws:war:0.0.29` 端到端启动并验证 HTTP 响应与
  docBase 清理；`--engine=undertow` 切换 undertow 引擎（默认复用
  `~/.m2/repository` 缓存）。

```bash
dub build -b release --compiler=ldc2
bash test/smoke.sh
```

## 打包（deb/rpm）

脚本放在 `scripts/`，仿照 micdn：

| 脚本 | 说明 |
|------|------|
| `scripts/build_common.sh` | `jstart_prepare_release_build`：`dub clean` → 清空 `target/` → `release-nobounds` 构建 |
| `scripts/build_rpm.sh` | Fedora/RHEL：产出 `target/jstart-<v>-<r>.<arch>.rpm`，Revision 自动取 `1.fcNN`/`1.elNN`，`%changelog` 从 `CHANGELOG.md` 生成 |
| `scripts/build_deb.sh` | Debian/Ubuntu：产出 `target/jstart_<v>-<r>_amd64.deb`（需 `dpkg-deb`、`fakeroot`） |

两个脚本都会先做 release 构建，然后：

- 复制 `target/jstart` → `usr/bin/jstart`，`strip --strip-unneeded`；
- 定位为命令而非系统服务：只安装 `/usr/bin/jstart` 命令本身（无 systemd 单元、
  无 `%post`/`postinst` 服务启停脚本、无默认配置、无独立用户）；
- `Requires`/`Depends: curl`（java 仅 run 时按需存在，不作为安装依赖）。

示例：

```bash
bash scripts/build_rpm.sh          # Fedora 44 → target/jstart-0.0.1-1.fc44.x86_64.rpm
bash scripts/build_deb.sh          # Debian/Ubuntu → target/jstart_0.0.1-1_amd64.deb
```

## 发布核对单

1. `CHANGELOG.md` 增加版本条目，并在条目末尾链接 `docs/release-vX.Y.Z.md`；
2. 同步 `dub.json` 与 `source/app.d` 里的版本号；
3. `dub test` + `bash test/smoke.sh` 全绿；
4. 各平台打包：`scripts/build_rpm.sh`、`scripts/build_deb.sh`；
5. 用 `rpm -qpl`/`dpkg-deb -c` 抽查包内容。
