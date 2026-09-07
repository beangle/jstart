# Release v0.0.1

发布日期：2026-09-07

首个版本。目标：把 beangle/boot 的"解析 + 准备依赖环境 + 轻量启动"用 D 语言做成
单原生二进制，并保留 launch.sh 式脚本解耦能力。

## 版本范围

- 命令：`run` / `resolve` / `classpath` / `repo`
- 目标：本地 jar/war、解压目录、文本依赖文件、gav、`gav://`、`http(s)://`
- 依赖描述：与 beangle/boot 格式兼容（jar 的 `META-INF/beangle/dependencies`、
  war 的 `WEB-INF/classes/...`）
- 仓库：本地默认 `~/.m2/repository`；远程默认阿里云 public → 华为云 maven →
  Maven Central，可 `--remote=` 覆盖
- 下载：宿主 curl 命令（仿 micdn），`.sha1` 校验，坏件删除重下
- 启动：`run` 解析后 `execvp` 为 java（POSIX；Windows 退化为子进程等待）
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

- `run` 只支持带 `Main-Class` 的 jar；war 的引擎启动（对标 beangle sas）未实现。
- 原生可执行二进制目标未接入（`launcher.runNativeApp` 入口已预留）。
- 下载为串行单连接：未实现 Range 多线程分段与断点续传。
- SNAPSHOT 时间戳版本（`~/.m2/snapshots`）与 zip/war/ear 的 `.diff` 增量补丁未实现。
- Windows `run` 无 exec 语义（`spawnProcess + wait`），退出码可传播但进程关系不同。
- 依赖描述行的 `g:a:v` 若含 `-` 分隔的 classifier 等非常规写法，请使用 4/5 段
  显式格式。
- 不做传递依赖解析（项目约束）：描述文件为依赖唯一来源，运行期依赖须显式写全。

## 路线图

- war run（内嵌 undertow/tomcat 引擎）与任意原生可执行二进制启动。
- Range 多线程分段下载、断点续传与下载进度增强。
- SNAPSHOT 时间戳解析与 .diff 增量补丁。
- Windows 原生支持与 launch.bat 式脚本入口。
