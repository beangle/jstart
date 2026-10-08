# jstart 文档

jstart 是用 D 语言实现的轻量 jar/war booter，功能对标
[beangle/boot](https://github.com/beangle/boot)（Scala 版）。以**启动 Java 工件（jar/war）
为主**，同时保留通用组件的扩展能力（通用运行时命名与同形 exec 入口），当前只实现并验证
java。本目录存放项目文档。

## 文档索引

| 文档 | 内容 |
|------|------|
| [design.md](design.md) | 设计思路：与 beangle/boot 的对应关系、exec 启动、模块架构、依赖准备流程 |
| [commands.md](commands.md) | 命令详解：`run`/`resolve`/`classpath`/`repo`/`fetch`、选项、退出码与示例 |
| [dependencies.md](dependencies.md) | 依赖描述文件格式：gav 规则、jar/war 存放位置、路径展开、构建端生成方式 |
| [launch-spec.md](launch-spec.md) | 启动说明文件：ini 式 spec 的格式、[libs]/[engine] 语义、run --print 与范围规划 |
| [war-engine.md](war-engine.md) | war 运行：何时启用、`[engine] init` init 命令、`[engine]` 依赖罗列、参数与限制 |
| [engine.md](engine.md) | **引擎 init 命令协议**：两阶段启动、argv 文件、`--entry` 语义、多 webapp 交付文件（`<base>/engine-subapps.jstart`，spec 片段）、classpath 文件与 docBase 归属 |
| [offline.md](offline.md) | 离线部署：仓库整合、无外网机器上的启动方式与注意事项 |
| [build.md](build.md) | 构建、测试与打包：dub/release、单测与冒烟、deb/rpm 脚本、产物布局 |
| [release-v0.0.1.md](release-v0.0.1.md) | v0.0.1 发布说明：范围、已知限制与路线图 |

## 快速开始

```bash
dub build -b release --compiler=ldc2          # 产物 target/jstart
./target/jstart run app.jar --port=8080       # 解析依赖后 exec 为 java
./target/jstart resolve app.jar                # 只准备依赖环境，输出应用路径
./target/jstart repo app.jar --local=/opt/offline-repo   # 离线仓库整合
./target/jstart fetch g:a:tar.gz:linux-amd64:4.20.14-SNAPSHOT   # 取发行包（优先增量补丁）
./target/jstart resolve g:a:tar.gz:linux-amd64:4.20.14-SNAPSHOT # 取包+解压，输出包内可执行文件
```

运行期依赖：

- `curl`：所有下载都调用宿主 curl 命令（仿 micdn），不链接 libcurl。
- `java`：仅 `run` jar 时按需使用（`JAVA_HOME` 或 PATH）；`resolve`/`classpath`/`repo` 不需要。
- `bspatch`：可选，`fetch` 打补丁时优先使用（`PATH` 上有就用）；失败自动回退内置实现。
- `bzip2` / `gzip`：仅 `fetch` 走增量补丁时需要（解压补丁内的 bzip2 流；tar.gz 还要重压）；
  缺对应命令时 `fetch` 只下载整包。
- `tar`：仅 native（tar.gz）目标解压时需要（`tar -xzf`）。

## 命令与功能一览

- `run <target> [args...]`：解析并准备依赖，然后 **exec 为 java**（进程即应用本身，无 jstart
  父子等待）；`--port=8080` 等参数原样传给应用，`-D`/`-X` 开头参数归运行时（即 JVM 参数）。
  launch spec target 用 `[app] runtime`/`[runtime]` 通用命名，便于替换 JDK，也为后续其他
  运行时预留。
- `run <spec>`（`[app] entry` 为 war/目录）：war **必须**通过 launch spec 运行（裸 war
  目标会报错并提示写 spec）——jstart 先运行**引擎 init 命令**准备环境（解压 war/发行包、
  生成容器配置、推导 docBase），再 exec 它写出的最终命令。引擎必须**显式声明**：`[engine]
  init = <路径|命令>` 指定 init 命令（最简是可执行文件/脚本**路径**，也可带参数；
  不是 java 类；`~`/`${VAR}` 会展开），
  `[engine]` 其余行逐行罗列引擎 + 容器 jar（jstart 不内置任何依赖目录，无占位符，见
  [engine.md](engine.md)、[war-engine.md](war-engine.md)）。
  `[app] engine` 已移除（写了会被告警忽略）。
  `resolve`/`fetch`/`repo` 仍可直接接受 war 文件/gav。多 webapp 用若干 `[subapp <id>]`
  段（`entry`+`path`，可选 `libs` 扩展依赖）声明，必须给 `[engine] init`；init 命令在同一
  JVM 里为每个 webapp 各建一个 context（外部引擎工具的多 context 入口 + 发行包 jar），
  各 webapp 依赖由各自 Context 隔离解析，见 [engine.md](engine.md)。
- `resolve <target>`：下载缺失依赖到本地仓库（默认 `~/.m2/repository`；release 与 SNAPSHOT
  同库同布局，SNAPSHOT 时间戳文件就在对应版本目录里；SNAPSHOT 每次向上游解析最新构建：
  HEAD 别名读 micdn 的 `latest` 头，其次版本目录的 `maven-metadata.xml`，本地已有该时间戳
  文件且 `.sha1` 通过就不再下载，上游不可达时退回本地已有），成功输出应用绝对路径。tar.gz
  （native）目标复用 `fetch` 的发行仓库逻辑取包并解压，输出**包内可执行文件**的绝对路径。
- `classpath <target>`：输出 `Main-Class@classpath`，供 launch.sh 风格脚本解耦使用。
- `info <target>`：依赖就绪后输出结构化信息（app/main/每个依赖的来源、本地落盘路径
  与体积、仓库位置），供审计与 CI 集成。
- `repo <target> [--source=<dir>]`：把依赖描述中 local 仓库缺失的构件从 source 仓库复制过来（含 `.sha1`），成功后输出 local 仓库基目录。
- `fetch <target> [--from=<version>]`：把目标取到本地并输出本地绝对路径。gav 走发行仓库
  （默认 beangle native 仓库），有可用的 bsdiff 增量补丁时只下补丁（重建后校验 `.sha1`），
  没有则整包下载；发行包侧不做快照元数据解析，`-SNAPSHOT` 只当字面版本名（本地命中即
  复用，否则增量/整包下载）；`http(s)` url 直接下载并按主机路径
  缓存；本地文件原样返回。gav 支持
  classifier（`group:artifact:tar.gz:linux-amd64:4.20.14-SNAPSHOT`）。SNAPSHOT 与正式版
  都落在/优先命中 `~/.m2/repository` 的对应版本目录（SNAPSHOT 目录里先取最新时间戳文件）；
  tar.gz 补丁按“解压后再压回”处理，jar/war 补丁直接作用于构件。
- `run <tar.gz 目标>`：同 `fetch` 取包（gav 含增量补丁）后解压到 `<base>/app`
  （base = `<base 根>/<组件键>`，根默认 `/var/tmp/jstart`，`--base` 或 spec 的
  `[app] base`/`[app] instance` 可换）并
  **exec 包内可执行文件**；参数按序附加在其后
  （native 无 JVM，命令行 `-D`/`-X` 也归应用），位置用 launch spec `[app] exec=` 指定
  （缺省探测 `<name>/bin/<exe>`）。native 侧**不对 `-SNAPSHOT` 特殊照顾**：不做快照元数据
  探测，`-SNAPSHOT` 只是字面版本名（本地命中 → 增量补丁 → 整包下载）。`classpath` 对
  native 报错，`info` 输出 `type: app`、`entry type: native` 与 `archive`/`root`。

目标（target）支持：

- 本地 jar、解压后的 war 目录、native 发行包 `*.tar.gz`；war 文件仍是 `resolve`/`fetch`/
  `repo` 的目标，`run` 时须声明在 launch spec 的 `[app] entry` 里
- launch spec `.jstart`（本地路径，或 `http(s)://host/path/app.jstart` 远程 spec）
- `group:artifact:version`、`gav://group:artifact:version`、`http(s)://host/path/app.jar`
- native gav：`group:artifact:tar.gz:classifier:version`（走发行仓库，含增量补丁）

主要选项：

- `--local=<dir>` 本地仓库（默认 `~/.m2/repository`；release 与 SNAPSHOT 同库同布局，
  SNAPSHOT 时间戳文件在对应版本目录里；SNAPSHOT 每次向上游解析最新时间戳文件，
  本地已有同一构建时不重复下载）
- `--remote=<urls>` 逗号分隔远程仓库：**正式版**用，缺省阿里云 public、华为云 maven、
  Maven Central，显式给出时也会补 Central
- `--snapshot-remote=<urls>` 可选，**仅 SNAPSHOT** 的开发版上游（逗号分隔）：**不兜到
  `--remote`**，也不含默认镜像与 Central 兜底；不配时本地仓库命中即用（不发请求、
  不报错），只有本地缺失、需要拉取才报错
- `--offline` 只用本地仓库：不探测远端（含 SNAPSHOT 的 `latest`/元数据探测）、不下载，
  缺件直接失败
- `--source=<dir>` repo 命令的源仓库（默认 `~/.m2/repository`，须与 `--local` 不同）
- `--base=<dir>` base 根目录，替换缺省的 `/var/tmp/jstart`；组件的运行目录是
  `<base>/<组件键>`，native 解压（`app/`）、war 解压（`webapps/`）都在其下；
  缺省根不可用时必须显式指定
- `[app] instance = <name>`（launch spec，无命令行选项）显式命名组件目录
  （`<根>/<name>`，不拼指纹）：同一组件跑多个副本时给每个副本一个 base，避免共用运行目录
- `--main=<class>` 指定 java 主类，优先于 `[app] main` 与 jar 内
  `Main-Class`；只对 jar/gav-jar/解压目录生效，war/native 目标告警忽略
- `--verbose`/`-v` 输出解析、下载、
  init 命令的 stdout 与将执行的启动命令等过程细节（默认只输出告警/错误与命令结果），
  `--quiet` 在默认之上再关闭告警（`--verbose` 与 `--quiet` 同给时以 `--quiet` 为准）
- `--print` 仅 run：打印将执行的命令行（逐参数引号）而不 exec；`--jobs=N` 并行下载
  并发数（默认 10，1 = 串行）

更多细节见各篇文档。
