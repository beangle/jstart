# Changelog

## Unreleased

- **war 引擎协议**：应用依赖 classpath 改由文件传递——jstart 写
  `<base>/engine-app.classpath`，入口 main 用 `--app-classpath-file=` 读取，避免命令行
  过长；入口 main 写出的最终命令过长时会折叠成 java 参数文件（`java @<file>`），由
  java launcher 展开
- **全量 tomcat**：`[app] engine = org.beangle.sas.engine.tomcat.ServerCreator` 可用（原
  beangle/sas `TomcatMaker` 的能力已收敛到该入口 main）：解压并精简 tomcat 发行包、
  生成 `conf/web.xml`/`conf/server.xml`、装 lib，`--jsp=`/`--listener=`/`--dist=` 等经
  `[args]` 或命令行透传
- **多 webapp spec**：单个 spec 用若干 `[subapp <id>]` 段（`entry`/`path`）声明多个
  webapp，由一个 **Dist 引擎**在同一 JVM 里各建一个 context。多应用只走 Dist 模式
  （内嵌 `tomcat`/`undertow` 别名与 `*EmbedCreator` 在校验阶段被拒），`[app] engine` 省略
  时缺省 ServerCreator；jstart 逐个取回 webapp 并把各自依赖补齐到本地仓库（运行时由每个
  Context 自己的 `DependencyClassLoader` 按 war 清单解析，不合并进同一 JVM classpath），
  把 `id \t entry \t path` 写进 `<base>/engine-webapps.tsv` 用 `--webapps-file=` 下发；
  `resolve`/`info` 按 webapp 逐个输出，`classpath` 明确拒绝，`stop` 一次停整组
- **spec 互斥校验**：`[app] main` 与 `[app] engine`/`[engine]` 互斥，同时声明直接报错
  （jar 跑主类、war 跑引擎 entry main，语义冲突）
- **实例目录与 `stop`**：`stop <target>` 按 pid 文件停止 `run` 启动的实例（SIGTERM；
  `--timeout=<sec>` 缺省 15 秒，`--force` 超时后 SIGKILL；未运行 exit 3 并清理残留
  pid 文件）。实例身份 = 组件键 + base，`--base=<dir>` 换 base 根（默认
  `/var/tmp/jstart`）、`--instance=<name>` 命名副本目录（`<根>/<name>-<组件指纹>`），
  同一 base 只跑一个实例
- **`--main=<class>` 覆盖主类**：run/classpath/info 指定 java 主类，优先于
  `[app] main` 与 jar 内 `MANIFEST.MF` 的 `Main-Class`；只对 jar/gav-jar/解压目录生效，
  war/native 目标告警忽略（空值或明显不是类名时用法错误 exit 2）
- **输出节制**：默认只输出告警/错误与命令结果；`--verbose`/`-v` 追加解析、下载、写 pid、
  引擎入口 main 的 stdout 与将执行的启动命令等过程细节，`--quiet`/`-q` 在默认之上再关闭
  告警（两者同给以 `--quiet` 为准，错误仍由退出码体现）
- 引擎入口 main 的命令行附带 `--Dsas.repo=<本地仓库>`（jstart 的 `--local`，默认
  `~/.m2/repository`），供容器内 `DependencyClassLoader` 解析 war 内置依赖

## v0.0.1 (2026-09-07)

首个版本：仿照 beangle/boot 思路、用 D 语言实现的轻量 jar/war booter，单二进制（约 470KB，无 JVM/运行时依赖）。

- **命令**：`resolve`（解析并下载依赖、输出应用路径）、`classpath`（输出 `Main-Class@classpath`）、`run`、`repo`（离线仓库整合）
- **启动**：`run` 解析并准备依赖环境后，通过 `exec` 将自身进程替换为 `java`——最终进程即 java，无 jstart 父子等待，退出码/信号/stdio 与直接运行 java 一致
- **解析**：支持 jar/war/解压目录/文本依赖文件/`g:a:v`/`gav://`/`http(s)://` 目标；读取 jar 内 `META-INF/beangle/dependencies`（war 为 `WEB-INF/classes/...`），依赖行格式与原版兼容（gav、4/5 段 packaging/classifier、本地文件、远程 url，支持 `~`/`${VAR}`/`file://`）
- **下载**：调用宿主 `curl` 命令（仿 micdn 实现，`--fail -L` 等参数），不再链接 libcurl；下载后自动拉取 `.sha1` 校验，损坏/不匹配构件删除重下；远程仓库默认阿里云 public → 华为云 maven → Maven Central，支持 `--remote=` 覆盖与 `--local=` 指定本地仓库
- **repo**：仿照 `org.beangle.boot.launcher.Repo`，把目标应用缺失的构件（jar + `.sha1`）从 `--source` 仓库复制到 `--local` 仓库，供无外网机器离线启动
- **启动说明文件（launch spec）**：`run`/`resolve`/`classpath`/`repo` 支持 `.launch`/`.jstart`
  目标，ini 式声明 `[app]`/`[runtime]`/`[args]`/`[deps]`（通用运行时命名，旧 `[jvm]`/
  `[app] java` 告警移除）；新增 `info` 子命令与 `run --print`（打印将执行的命令）
- **下载**：多依赖并行（`--jobs`，默认 10）与单文件 Range 分段并行（≥1MB 最多 4 段，
  失败回退单请求）；SNAPSHOT 别名按上游元数据解析最新时间戳构建（micdn 的 `latest`
  响应头，其次版本目录的 `maven-metadata.xml`），落到独立快照库（`~/.m2/snapshots`，
  不与 repository 混合）；本地已有同一构建即用，上游不可达时回退本地最新时间戳文件，
  上游没有这类元数据时按字面文件名处理
- **离线**：新增 `--offline`，只用本地仓库——不探测、不下载（SNAPSHOT 也不再查
  `latest`/`maven-metadata.xml`），缺件直接失败；内置默认镜像与 Central 兜底只由
  `buildRemotes` 决定，调用方只需透传自己的仓库列表
- **SNAPSHOT 上游与正式版分开**：`--remote` 的默认镜像与 Central 兜底只作用于正式版；
  开发版专用新的 `--snapshot-remote=`（可选；**不兜到 `--remote`**，
  `buildSnapshotRemotes` 不追加 Central、不给默认镜像）；没配快照上游时本地快照库命中
  即用（不发请求、不报错），只有本地缺失、需要拉取才报错，不再因为"没配快照上游"而回落
  到公共镜像
- **fetch/native 不做快照语义**：发行包侧（`fetch` 与 native tar.gz gav）不再对 `-SNAPSHOT`
  做 `latest` 头/`maven-metadata.xml` 探测（native 构建费时、包大、发布不频繁，开发版一般
  不上传），只当字面版本名走「本地命中 → 增量补丁 → 整包下载」；`--snapshot-remote` 仅作用
  于 maven 依赖解析
- **war 引擎运行**：war 只能从 launch spec 进入 `run`（`[app] entry` 为 war 文件/gav；
  裸 war 目标对 `run` 直接报错，`resolve`/`fetch`/`repo` 仍直接接受 war）。jstart 把
  war/已解压目录交给**引擎入口 main**（`org.beangle.sas.engine.<name>.EmbedCreator`，可用
  FQCN 覆盖）：入口 main 准备环境、把最终 argv 写入 `engine-entry.argv` 后退出，jstart
  再 exec；war 的解压与 docBase 布局归引擎（jstart 不再自己爆炸，跨仓库契约取消，见
  docs/engine.md）。`[app] engine` 选入口 main、`[engine]` 段显式罗列引擎依赖以覆盖
  内置默认（tomcat/undertow）；`--base` 例外解析，`--path`/`--port` 等原样透传
- **引擎内置目录（undertow）**：对齐 sas 0.13.17 的 Jakarta EE 10 拆分——
  `io.undertow.ee:undertow-servlet/-websockets`（不再用 `io.undertow:undertow-servlet`）、
  undertow-core 2.4.4/XNIO 3.8.16/jboss 3.6.3+3.9.2/wildfly 2.0.1，并补齐
  `jakarta.servlet-api`/`jakarta.websocket(-client)-api` 与 wildfly-common 需要的
  smallrye-common（含 net/os/ref）共 22 个 jar；此前的目录缺 servlet API，`engine = undertow`
  会在启动时 `NoClassDefFoundError`
- **工程**：纯 Phobos 零 dub 依赖；`scripts/build_common.sh` + `build_deb.sh` + `build_rpm.sh` 打包（产物 `target/`）；下载改用宿主 curl 后 release 二进制约 470KB
- **测试**：单元测试覆盖 CLI 选项解析、gav/布局解析、sha1 校验、jar/war/目录/文本依赖文件解析、zip/Manifest 读取、引擎选择与 argv 解析、repo 整合复制；`test/smoke.sh` 端到端验证 resolve/classpath/缓存命中/gav/run 参数转发、war `--print` 与"入口 main 写 argv → exec"（本地 FakeEngine，不联网）；`test/war-run-test.sh` 用真实组件 `org.beangle.otk:beangle-otk-ws:war:0.0.29` 验证 tomcat/undertow 引擎启动（可选，联网+大下载）

完整说明见 docs/release-v0.0.1.md
