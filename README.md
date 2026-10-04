# jstart - 轻量级 Java 工件（jar/war）启动器（D 语言）

jstart 是用 D 语言实现的轻量级 Java 工件启动器：面向 jar/war，以轻量方式解析应用、下载缺失的
Maven 依赖、准备依赖环境，并 exec 成 `java` 启动应用。它本身是独立的原生可执行文件，定位是
**命令**而非常驻服务。

> **定位**：以 Java 工件为主——jar（带 `Main-Class` 的瘦 jar）与 war（内置 tomcat/undertow
> 引擎）；同时支持 GraalVM native 发行包（tar.gz）：取包（复用 `fetch`，gav 含增量补丁）、
> 解压、直接 exec 包内可执行文件，参数附加在其后。launch spec 的目标与运行时字段
> （entry/runtime/`[runtime]`）采用通用命名，`launcher.runNativeApp` 与 java 走同一 exec
> 入口，其他运行时仍可继续扩展。

## 特性

- 目标支持：本地 jar、解压 war 目录、`g:a:v`/`gav://`、`http(s)://` url；war 仍是
  `resolve`/`fetch`/`repo` 的目标，但 `run` 时**必须**写进 launch spec 的
  `[app] entry`（裸 war 目标会报错并提示）。`run` 的声明式目标为 launch spec
  （`.jstart`，支持本地路径或 http(s) url，见 [docs/launch-spec.md](docs/launch-spec.md)）。
- 读取应用内置依赖清单（jar：`META-INF/beangle/dependencies`；war：`WEB-INF/classes/...`），
  逐行准备 gav/本地文件/远程文件三类依赖。
- 缺失依赖下载到本地 Maven 仓库（默认 `~/.m2/repository`），`.sha1` 校验、损坏删除重下；
- **快照库独立**：SNAPSHOT 时间戳构件（`a-1.0-<yyyyMMdd.HHmmss>-<build>.jar`）放在
  单独的 `~/.m2/snapshots`，**不与 `~/.m2/repository` 混合**。每个 SNAPSHOT 都先向上游解析
  「最新构建」——HEAD 别名读 micdn 的 `latest` 响应头，其次版本目录的 `maven-metadata.xml`；
  解析出的时间戳文件已在本地且 `.sha1` 通过就跳过下载，否则下载。上游不可达时退回本地已有
  的最新时间戳文件，离线仍可用。
  正式版远程默认阿里云 → 华为云 → Maven Central，可 `--remote=` 覆盖；SNAPSHOT 上游用
  `--snapshot-remote=`（可选，**不兜到 `--remote`**）；没配快照上游时本地快照库命中即用
  （不发请求、不报错），只有本地缺失、需要拉取才报错（`--offline` 只是不联网、不拉取）。
- `stop` 子命令按 **base** 停止 `run` 启动的实例：`run` 在 exec 前把 pid 写入
  `<base>/app.pid`（base = `<base 根>/<组件键>`，根默认 `/var/tmp/jstart`；`--base=<dir>`
  整体替换这个根，launch spec 可用 `[app] base` 固定根、`[app] instance` 固定组件目录名）。
  **实例身份 = 组件 + base，与应用参数无关**：一个 base 只能跑一个实例，重复启动会被拒绝
  （`--force` 可覆盖），`stop <target>` 不需要重复 run 时的参数；要跑多个副本就给每个副本
  一个 base。
  `stop` 先 SIGTERM，`--timeout`/`--force` 控制等待与 SIGKILL。
- `fetch` 子命令负责把目标取到本地：gav（支持 classifier）从发行仓库取 native tar.gz/jar/war，
  本地有基线且远端有 bsdiff 增量时只下补丁，否则整包下载；`http(s)` url 直接下载并按主机路径
  缓存；本地文件原样返回路径。没有补丁不是错误。tar.gz 的补丁按“本地基线 `gunzip` →
  bspatch → `gzip -n -6` → 校验 `.sha1`”处理，jar/war 直接 patch；打补丁优先用系统
  `bspatch`（`PATH` 上有就用，失败自动回退内置实现，`JSTART_BSPATCH` 可指定或强制内置）。
  发行包侧不做快照元数据解析（`-SNAPSHOT` 只当字面版本名）；SNAPSHOT 版本落在/优先命中
  `~/.m2/snapshots`，正式版落在 `~/.m2/repository`；
  `--remote` 指向配了 `<auth download-key>` 的 micdn 时，设置环境变量 `micdn_token` 让构件与补丁
  的下载带 `Authorization: Bearer`（HEAD 探测不受限，未设置时行为不变）。
- `run` 解析完毕后 exec 为 `java`：最终进程就是 java、无父子等待；`--port=8080` 等参数原样
  转发给应用，`-D`/`-X` 开头参数归运行时（即 JVM 参数）。launch spec 的 `[app] runtime`/
  `[runtime]` 用通用命名，便于替换 JDK/引擎，并为后续其他运行时预留
  （见 [docs/launch-spec.md](docs/launch-spec.md)）。
  主类按 `--main=<class>` > launch spec `[app] main` > jar 内 `MANIFEST.MF` 的
  `Main-Class` 确定：jar 的 Main-Class 不适用（或想跑 jar 里/依赖里的另一个类）时用
  `--main=` 覆盖，解压目录这类没有 manifest 的目标也靠它（war 由引擎 init 命令启动，
  native 用 `[app] exec`，给 `--main` 会告警忽略）。
- war 目标由 spec 声明的**引擎 init 命令**启动（不再有内置引擎/别名）：jstart 先运行
  `[engine] init = <路径|命令>`（准备容器环境、写出最终启动命令）再 exec 容器；组件目录
  默认是按组件隔离的 `/var/tmp/jstart/<组件键>`，`--base=` 可换根。`init` 是一条**命令行**
  （最简是可执行文件/脚本**路径**，也可带参数，如 `basctl make tomcat-dist`；不是
  java 类），jstart 不内置任何引擎目录，引擎与容器 jar 由 `[engine]` 其余行逐行写全
  （同 `[libs]` 语法）；见 [docs/war-engine.md](docs/war-engine.md)。
- 多 webapp：一个 spec 用若干 `[subapp <id>]` 段（`entry` + `path`）声明多个 war，
  `[engine] init` 命令负责在同一 JVM 里各建一个 context（通常用 basctl 的多 context 入口），
  各 webapp 依赖由各自 Context 的 `DependencyClassLoader` 隔离解析，一个 base 一份 pid
  （`stop` 一次停整组）；见 [docs/engine.md](docs/engine.md)。
- native（tar.gz）目标：`g:a:tar.gz:<classifier>:v`、本地 `*.tar.gz` 或 `http(s)` url 时，
  `resolve`/`run` 复用 `fetch` 的取包逻辑（gav 时优先增量补丁），解压到 `<base>/app` 后
  **exec 包内可执行文件**；参数按序附加在其后（native 无 JVM，`[args]`/命令行含 `-D`/`-X`
  全部归应用），可执行文件位置可用 launch spec `[app] exec=` 指定，缺省探测
  `<name>/bin/<exe>`，`resolve` 输出该可执行文件路径。native 侧**不对 `-SNAPSHOT` 特殊
  照顾**：不做快照元数据探测，`-SNAPSHOT` 只是字面版本名（本地命中 → 增量补丁 → 整包下载）。
  `--base=<dir>`（或 spec 的 `[app] base`/`[app] instance`）可改 base（不会写到包旁；
  `/tmp` 的 noexec、tmpfs、清理周期等影响见 [docs/commands.md](docs/commands.md)）。
- 下载走宿主 `curl` 命令（同 micdn 方式），不链接 libcurl；多依赖默认并行下载
  （`--jobs=10`），远端支持 Range 且大文件时自动分段并行。
- 输出分级：默认只输出告警/错误与命令结果（`resolve` 的路径、`classpath` 的
  `Main-Class@classpath`、`fetch` 的本地路径等）；`--verbose`/`-v` 追加解析、下载、
  写 pid、init 命令的 stdout 与将执行的启动命令等过程细节，`--quiet`/`-q` 则连
  告警也关闭。

> **项目约束**：不做传递依赖解析。依赖清单是依赖的唯一来源，应用的全部运行期依赖须由构建期
> beangle maven/sbt 插件显式写全；漏写不推导，`resolve`/`run` 会以 Missing 失败。

## 快速开始

```bash
dub build -b release --compiler=ldc2        # 产物 target/jstart

# 准备依赖环境并启动（进程即 java，参数原样透传）
./target/jstart run /path/to/app.jar --port=8080 --path=/base

# 只准备依赖环境，输出应用绝对路径（供脚本使用）
app=$(./target/jstart --quiet resolve /path/to/app.jar)

# 声明式启动：launch spec（.jstart，本地路径或 http(s) url）
# war 必须写进 [app] entry，并在 [engine] 里给 init 命令（--port/--path 透传给引擎）
cat > app.jstart <<'EOF'
[app]
entry = /path/to/app.war

[engine]
init = /opt/engine/bin/tomcat-init
org.beangle.sas:beangle-sas-engine:0.13.17
org.apache.tomcat.embed:tomcat-embed-core:11.0.24
org.apache.tomcat.embed:tomcat-embed-websocket:11.0.24

[args]
--port=8080
EOF
./target/jstart run app.jstart
./target/jstart run https://repo.example.com/app.jstart   # 远程 spec：下载后按 entry 解析

# 输出 Main-Class@classpath，供 launch.sh 式脚本自行 exec java
meta=$(./target/jstart --quiet classpath "$app")

# 输出结构化信息（app/main/依赖落盘路径与体积），供审计与 CI
./target/jstart --quiet info "$app"

# 后台运行 + 按 base 停止（一个 base 一个实例；多副本各给一个 base）
# 固定目录名 app-a 要写成 spec： [app] entry=... / base=/srv/jstart / instance=app-a
./target/jstart run /path/to/app-a.jstart --port=8081 &
./target/jstart stop /path/to/app-a.jstart

# 离线整合：把依赖从 --source 仓库复制到 --local 仓库
./target/jstart repo "$app" --local=/opt/offline-repo

# 取发行包（native tar.gz 等），有 bsdiff 增量补丁则只下补丁
./target/jstart fetch org.beangle.ems:beangle-ems-portal:tar.gz:linux-amd64:4.20.14-SNAPSHOT --from=4.20.13

# fetch 也接受 url / 本地文件（它就是"下载并给出本地路径"）
./target/jstart fetch https://host/path/app-1.0-linux-amd64.tar.gz
./target/jstart fetch ./app-1.0-linux-amd64.tar.gz

# native（tar.gz）：取包 -> 解压 -> 运行，参数附加在可执行文件之后
boot=$(./target/jstart --quiet resolve org.beangle.ems:beangle-ems-portal:tar.gz:linux-amd64:4.20.14-SNAPSHOT)
"$boot" --port=8080
./target/jstart run org.beangle.ems:beangle-ems-portal:tar.gz:linux-amd64:4.20.14-SNAPSHOT --port=8080
```

## 构建与测试

需要 D 工具链（dub + ldc2/dmd）；运行机需 `curl`，`run` jar 时还需 `java`（`JAVA_HOME` 或 PATH）。

```bash
dub test --compiler=ldc2    # 单元测试（独立于 test/jstart/，仿 micdn 布局）
bash test/smoke.sh          # 端到端冒烟测试（需先 release 构建）
```

Deb/RPM 安装包脚本在 `scripts/`（`build_rpm.sh`、`build_deb.sh`，仿 micdn）：仅安装
`/usr/bin/jstart`，定位为命令而非系统服务。

## 文档

命令详解、依赖文件格式、离线部署、设计思路、构建打包与发布说明等详见 `docs/`
（入口：[docs/README.md](docs/README.md)）。

## License

GPL-3.0-or-later，全文见根目录 [LICENSE](LICENSE)。
