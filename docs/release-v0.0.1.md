# Release v0.0.1

发布日期：2026-09-07

首个版本。目标：把 beangle/boot 的"解析 + 准备依赖环境 + 轻量启动"用 D 语言做成
单原生二进制，并保留 launch.sh 式脚本解耦能力。

## 版本范围

- 命令：`run` / `resolve` / `classpath` / `info` / `repo`
- 目标：本地 jar/war、解压目录、launch spec（`.launch`/`.jstart`）、gav、`gav://`、
  `http(s)://`（纯文本依赖清单已不支持）；war 作为 `run` 目标时须写进 launch spec 的
  `[app] entry`，`resolve`/`fetch`/`repo` 仍可直接接受
- 依赖描述：与 beangle/boot 格式兼容（jar 的 `META-INF/beangle/dependencies`、
  war 的 `WEB-INF/classes/...`）
- 仓库：release/普通构件进本地仓库（默认 `~/.m2/repository`）；SNAPSHOT 时间戳构件进
  **独立的快照库**（默认 `~/.m2/snapshots`，不与 repository 混合；显式 `--local` 时
  也定位到该 base 的快照路径）；SNAPSHOT 别名按上游解析成最新时间戳文件（HEAD 别名的
  micdn `latest` 头，或版本目录的 `maven-metadata.xml`），本地已有同一构建时跳过下载；
  远程默认阿里云 public → 华为云 maven → Maven Central，可 `--remote=` 覆盖
  （默认镜像与 Central 兜底只作用于正式版；SNAPSHOT 只用显式给出的仓库，缺省为空，
  需要完全不出网时用 `--offline`）
- 下载：宿主 curl 命令（仿 micdn），`.sha1` 校验，坏件删除重下
- 启动：`run` 解析后 `execvp` 为 java（POSIX；Windows 退化为子进程等待）；launch spec
  采用通用运行时命名（`[app] runtime` + `[runtime]` 段，旧 `[app] java`/`[jvm]` 已移除并告警）
- war 引擎：war 只能从 launch spec（`[app] entry` 为 war/目录）进入 `run`，裸 war 目标
  会报错（`resolve`/`fetch`/`repo` 仍直接接受 war）；jstart 运行**引擎入口 main**准备
  环境、再 exec 它写出的最终命令（入口 main 为 `org.beangle.sas.engine.<name>.EmbedCreator`，
  全量 tomcat 用 `tomcat.ServerCreator`；tomcat/undertow 均有内置默认依赖目录，`[app] engine`
  选入口 main、`[engine]` 段罗列引擎依赖覆盖内置默认；war 的解压与 docBase 归引擎，
  见 [engine.md](engine.md) 与 [war-engine.md](war-engine.md)）
- 打包：`scripts/build_rpm.sh`、`scripts/build_deb.sh`（含 `build_common.sh`）
- 工程：零 dub 第三方依赖；单元测试独立于 `test/jstart/`（仿 micdn）+ `test/smoke.sh`
  端到端冒烟

## 与 beangle/boot 差异

- 解析阶段不再需要 JVM：jstart 本身是原生二进制（release 约 470KB）。
- `run` 合并 resolve/classpath 两步后用 exec 交付 java；`resolve`/`classpath` 仍保留，
  供 shell 脚本按 launch.sh 思路自行执行 java。
- 新增基于宿主 curl 的下载实现，默认不链接 libcurl。
- `repo` 子命令对齐 `launcher.Repo`，用于离线仓库整合。

## 已知限制

- `run` jar 目标需带 `Main-Class`；war 目标必须先写进 launch spec（`[app] entry`），
  再走内置引擎（tomcat/undertow 均有内置默认目录，锁版本/换镜像用 `[engine]` 段覆盖）；
  裸 war 目标对 `run` 报错。可执行 war（自带 Main-Class）与"解压目录目标走引擎"暂不支持。
- native（tar.gz）目标已接入：`fetch` 取包（含增量补丁）、解压、exec 包内可执行文件，
  参数按序附加（见 [commands.md](commands.md) 的 "native（tar.gz）目标"）；launch spec
  的 `[app] runtime` 取非 java 值（python3/node 等）仅为结构与文档预留，java 目标仍只
  exec java。
- 无跨次运行的断点续传；`fetch` 支持 bsdiff 增量补丁（native tar.gz 解压后比对、
  jar/war 直接比对）。
- SNAPSHOT 解析每次都会先探测上游（别名 HEAD 的 `latest` 头，或版本目录的
  `maven-metadata.xml`），离线机器上依赖 SNAPSHOT 时每次解析会多一次网络尝试
  （失败后退回本地快照库，不影响使用）；增量补丁支持 native tar.gz（解压后比对）与
  jar/war（直接比对），zip/ear 等其他打包类型不实现。
- Windows `run` 无 exec 语义（`spawnProcess + wait`），退出码可传播但进程关系不同。
- 依赖描述行的 `g:a:v` 若含 `-` 分隔的 classifier 等非常规写法，请使用 4/5 段
  显式格式。
- 不做传递依赖解析（项目约束）：描述文件为依赖唯一来源，运行期依赖须显式写全。

## 路线图

- v0.1.0：launch spec 启动说明文件（`docs/launch-spec.md`）、`run --print` 与
  `info` 结构化输出命令均已随 v0.0.1 落地；war 引擎 run（tomcat/undertow）已实现
  （见 [war-engine.md](war-engine.md)）。项目以 Java 工件（jar/war）为主，同时保留
  通用运行时的扩展能力。
- war run：tomcat 与 undertow 引擎均已落地（war 由 launch spec 的 `[app] entry` 声明；
  引擎入口 main/内置默认依赖/`[app] engine`+`[engine]`；docBase 归引擎），并支持已解压
  webapp 目录直接作为 `--entry`；tomcat 已用 `org.beangle.otk:beangle-otk-ws:war:0.0.29`
  完成真实运行验证。
- 多依赖并行下载（`--jobs`）与单文件 Range 分段并行（远端支持且 ≥1MB，最多 4 段）
  已实现；后续：跨次运行断点续传。
- 下载进度显示：**明确不做**——下载期间不输出进度条；默认也不输出下载结果行，
  只在 `--verbose` 时给出每个文件下载完成后的 `Downloaded ...`，与"命令型轻量工具、
  输出可管道"的定位一致。
- SNAPSHOT 解析已实现：按上游解析最新时间戳文件（micdn 的 `latest` 头优先，其次
  `maven-metadata.xml` 的 `<snapshotVersions>`/`<snapshot>`），落盘到本地快照库
  `~/.m2/snapshots` 并复核 `.sha1`（同 release 语义），本地已有同一构建时跳过下载，
  上游不可达时退回本地最新时间戳文件；最后才回退远端 `-SNAPSHOT` 字面文件。
- Windows 原生支持与 launch.bat 式脚本入口。
