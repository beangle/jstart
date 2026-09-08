# jstart 文档

jstart 是用 D 语言实现的轻量 jar/war booter，功能对标
[beangle/boot](https://github.com/beangle/boot)（Scala 版）。本目录存放项目文档。

## 文档索引

| 文档 | 内容 |
|------|------|
| [design.md](design.md) | 设计思路：与 beangle/boot 的对应关系、exec 启动、模块架构、依赖准备流程 |
| [commands.md](commands.md) | 命令详解：`run`/`resolve`/`classpath`/`repo`、选项、退出码与示例 |
| [dependencies.md](dependencies.md) | 依赖描述文件格式：gav 规则、jar/war 存放位置、路径展开、构建端生成方式 |
| [launch-spec.md](launch-spec.md) | 启动说明文件：ini 式 spec 的格式、[deps]/[engine] 语义、run --print 与范围规划 |
| [war-engine.md](war-engine.md) | war 内置引擎：爆炸布局、[app] engine 选择、[engine] 依赖罗列、参数语义与限制 |
| [offline.md](offline.md) | 离线部署：仓库整合、无外网机器上的启动方式与注意事项 |
| [build.md](build.md) | 构建、测试与打包：dub/release、单测与冒烟、deb/rpm 脚本、产物布局 |
| [release-v0.0.1.md](release-v0.0.1.md) | v0.0.1 发布说明：范围、已知限制与路线图 |

## 快速开始

```bash
dub build -b release --compiler=ldc2          # 产物 target/jstart
./target/jstart run app.jar --port=8080       # 解析依赖后 exec 为 java
./target/jstart resolve app.jar                # 只准备依赖环境，输出应用路径
./target/jstart repo app.jar --local=/opt/offline-repo   # 离线仓库整合
```

运行期依赖：

- `curl`：所有下载都调用宿主 curl 命令（仿 micdn），不链接 libcurl。
- `java`：仅 `run` jar 时按需使用（`JAVA_HOME` 或 PATH）；`resolve`/`classpath`/`repo` 不需要。

## 命令与功能一览

- `run <target> [args...]`：解析并准备依赖，然后 **exec 为运行时**（当前即 java，进程即
  应用本身，无 jstart 父子等待）；`--port=8080` 等参数原样传给应用，`-D`/`-X` 开头参数归
  运行时（java 即 JVM 参数）。launch spec target 用 `[app] runtime`/`[runtime]` 通用命名。
- `run <war>`：war 目标自动进入内置引擎流程（爆炸到 `<base>/webapps/<ctx>` 后 exec
  `org.beangle.sas.engine.<name>.Bootstrap`，缺省 tomcat）。`[app] engine` 选引擎、
  `engine = tomcat-11.0.24` 可直接指定 tomcat 版本、`[engine]` 段罗列引擎依赖并支持
  `{tomcat.version}`/`{sas.version}` 占位符（见 [war-engine.md](war-engine.md)）。
- `resolve <target>`：下载缺失依赖到本地仓库（默认 `~/.m2/repository`；SNAPSHOT 时间戳构件
  走独立的 `~/.m2/snapshots`，不与 repository 混合），成功输出应用绝对路径。
- `classpath <target>`：输出 `Main-Class@classpath`，供 launch.sh 风格脚本解耦使用。
- `info <target>`：依赖就绪后输出结构化信息（app/main/每个依赖的来源、本地落盘路径
  与体积、仓库位置），供审计与 CI 集成。
- `repo <target> [--source=<dir>]`：把依赖描述中 local 仓库缺失的构件从 source 仓库复制过来（含 `.sha1`），成功后输出 local 仓库基目录。

目标（target）支持：

- 本地 jar/war、解压后的 war 目录（`run` 的声明式目标用 `.launch`/`.jstart` spec）
- `group:artifact:version`、`gav://group:artifact:version`、`http(s)://host/path/app.jar`

主要选项：

- `--local=<dir>` 本地仓库（默认 `~/.m2/repository`；SNAPSHOT 时间戳构件默认在独立的
  `~/.m2/snapshots`，显式给定时也定位到该目录下的快照路径）
- `--remote=<urls>` 逗号分隔远程仓库（默认阿里云 public、华为云 maven、Maven Central）
- `--source=<dir>` repo 命令的源仓库（默认 `~/.m2/repository`，须与 `--local` 不同）
- `--preferwar` gav 目标优先 war 打包；`--quiet` 关闭过程输出

更多细节见各篇文档。
