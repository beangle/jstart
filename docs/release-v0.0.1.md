# Release v0.0.1

发布日期：2026-09-07

首个版本。目标：把 beangle/boot 的"解析 + 准备依赖环境 + 轻量启动"用 D 语言做成
单原生二进制，并保留 launch.sh 式脚本解耦能力。

## 版本范围

- 命令：`run` / `resolve` / `classpath` / `info` / `repo`
- 目标：本地 jar/war、解压目录、launch spec（`.launch`/`.jstart`）、gav、`gav://`、
  `http(s)://`（纯文本依赖清单已不支持）
- 依赖描述：与 beangle/boot 格式兼容（jar 的 `META-INF/beangle/dependencies`、
  war 的 `WEB-INF/classes/...`）
- 仓库：release/普通构件进本地仓库（默认 `~/.m2/repository`）；SNAPSHOT 时间戳构件进
  **独立的快照库**（默认 `~/.m2/snapshots`，不与 repository 混合；显式 `--local` 时
  也定位到该 base 的快照路径）；远程默认阿里云 public → 华为云 maven → Maven
  Central，可 `--remote=` 覆盖
- 下载：宿主 curl 命令（仿 micdn），`.sha1` 校验，坏件删除重下
- 启动：`run` 解析后 `execvp` 为 java（POSIX；Windows 退化为子进程等待）；launch spec
  采用通用运行时命名（`[app] runtime` + `[runtime]` 段，旧 `[app] java`/`[jvm]` 已移除并告警）
- war 引擎：`run` 对 war 目标爆炸到 `<base>/webapps/<ctx>` 后 exec 内嵌引擎 Bootstrap
  （tomcat/undertow，均有内置默认依赖目录；`[app] engine` 选择、`[engine]` 段罗列引擎
  依赖用于覆盖内置默认；`--path`/`--base` 例外解析，见 [war-engine.md](war-engine.md)）
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

- `run` jar 目标需带 `Main-Class`；war 目标走内置引擎（tomcat/undertow 均有内置默认
  目录，锁版本/换镜像用 launch spec `[engine]` 段覆盖）。可执行 war（自带
  Main-Class）与"解压目录目标走引擎"暂不支持。
- 原生可执行二进制目标未接入（`launcher.runNativeApp` 入口已预留）；launch spec 的
  `[app] runtime` 取非 java 值（python3/node 等）仅为结构与文档预留，当前 `run` 仍只
  exec java（jar 目标）。
- 无跨次运行的断点续传；不做 boot 的 `.diff` 增量补丁下载与合并（按取舍决定）。
- SNAPSHOT 时间戳选取仅限本地快照库（`~/.m2/snapshots` 或 `--local` base），
  不解析远端 `maven-metadata.xml`；zip/war/ear 的 `.diff` 增量补丁不实现。
- Windows `run` 无 exec 语义（`spawnProcess + wait`），退出码可传播但进程关系不同。
- 依赖描述行的 `g:a:v` 若含 `-` 分隔的 classifier 等非常规写法，请使用 4/5 段
  显式格式。
- 不做传递依赖解析（项目约束）：描述文件为依赖唯一来源，运行期依赖须显式写全。

## 路线图

- v0.1.0：launch spec 启动说明文件（`docs/launch-spec.md`）、`run --print` 与
  `info` 结构化输出命令均已随 v0.0.1 落地；war 引擎 run（tomcat/undertow）已实现
  （见 [war-engine.md](war-engine.md)），后续任意原生可执行二进制启动。
- war run：tomcat 与 undertow 引擎均已落地（爆炸布局/内置默认依赖/`[app] engine`+
  `[engine]`），两种引擎均已用 `org.beangle.otk:beangle-otk-ws:war:0.0.29` 完成真实
  运行验证；后续：解压目录目标走引擎。
- 多依赖并行下载（`--jobs`）与单文件 Range 分段并行（远端支持且 ≥1MB，最多 4 段）
  已实现；后续：跨次运行断点续传。
- 下载进度显示：**明确不做**——下载期间不输出进度条，只在单个文件下载完成后输出
  结果行（`Downloaded ...`），与"命令型轻量工具、输出可管道"的定位一致。
- SNAPSHOT 下载逻辑已实现（远端 `-SNAPSHOT` 字面下载，下载后同 release 一样从
  同一远程复核 `.sha1`；本地快照库 `~/.m2/snapshots` 最新时间戳选取，镜像 boot
  `LocalSnapshot`；本地已命中时忽略 sha1）；不实现 `.diff` 增量补丁。
- Windows 原生支持与 launch.bat 式脚本入口。
