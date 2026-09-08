# jstart - 轻量级 jar/war 启动器（D 语言）

jstart 是用 D 语言实现的轻量级 jar/war 启动器：以轻量方式解析应用、下载缺失依赖、准备依赖环境，
并 exec 成 `java` 启动应用。它本身是独立的原生可执行文件，定位是**命令**而非常驻服务；后续也可
作为通用启动器拉起其他原生可执行二进制。

## 特性

- 目标支持：本地 jar/war、解压 war 目录、`g:a:v`/`gav://`、`http(s)://` url；
  `run` 的声明式目标为 launch spec（`.jstart`，支持本地路径或 http(s) url，见 [docs/launch-spec.md](docs/launch-spec.md)）。
- 读取应用内置依赖清单（jar：`META-INF/beangle/dependencies`；war：`WEB-INF/classes/...`），
  逐行准备 gav/本地文件/远程文件三类依赖。
- 缺失依赖下载到本地 Maven 仓库（默认 `~/.m2/repository`），`.sha1` 校验、损坏删除重下；
- **快照库独立**：SNAPSHOT 时间戳构件（`a-1.0-<yyyyMMdd.HHmmss>-<build>.jar`）放在
  单独的 `~/.m2/snapshots`，**不与 `~/.m2/repository` 混合**；本地命中最新时间戳即直接用，
  缺失才下载；
  远程默认阿里云 → 华为云 → Maven Central，可 `--remote=` 覆盖。
- `run` 解析完毕后 exec 为 `java`：最终进程就是 java、无父子等待；`--port=8080` 等参数原样
  转发给应用，`-D`/`-X` 开头参数归运行时（即 JVM 参数）。launch spec 用通用命名
  （`[app] runtime`/`[runtime]`，见 [docs/launch-spec.md](docs/launch-spec.md)），为后续
  非 java 运行时预留。
- war 目标用内置引擎启动：爆炸到 `<base>/webapps/<ctx>` 后 exec 引擎 Bootstrap（默认
  tomcat）；引擎选择与依赖可在 launch spec 声明（`[app] engine` + `[engine]` 段，
  见 [docs/war-engine.md](docs/war-engine.md)）。`engine = tomcat` 用内置默认版本，
  `engine = tomcat-11.0.24` 直接指定 tomcat 版本；`[engine]` 行支持
  `{tomcat.version}`/`{sas.version}` 占位符引用内置版本，不必手写重复版本号。
- 下载走宿主 `curl` 命令（同 micdn 方式），不链接 libcurl；多依赖默认并行下载
  （`--jobs=10`），远端支持 Range 且大文件时自动分段并行。

> **项目约束**：不做传递依赖解析。依赖清单是依赖的唯一来源，应用的全部运行期依赖须由构建期
> beangle maven/sbt 插件显式写全；漏写不推导，`resolve`/`run` 会以 Missing 失败。

## 快速开始

```bash
dub build -b release --compiler=ldc2        # 产物 target/jstart

# 准备依赖环境并启动（进程即 java，参数原样透传）
./target/jstart run /path/to/app.jar --port=8080 --path=/base

# war 走内置引擎：爆炸后启动内嵌 tomcat（--port/--path 透传给引擎）
./target/jstart run /path/to/app.war --port=8080 --path=/base

# 只准备依赖环境，输出应用绝对路径（供脚本使用）
app=$(./target/jstart --quiet resolve /path/to/app.jar)

# 声明式启动：launch spec（.jstart，本地路径或 http(s) url）
cat > app.jstart <<'EOF'
[app]
entry = /path/to/app.war
engine = tomcat-11.0.24        # 指定 tomcat 版本；engine = tomcat 则用内置默认版本

[args]
--port=8080
EOF
./target/jstart run app.jstart
./target/jstart run https://repo.example.com/app.jstart   # 远程 spec：下载后按 entry 解析

# 输出 Main-Class@classpath，供 launch.sh 式脚本自行 exec java
meta=$(./target/jstart --quiet classpath "$app")

# 输出结构化信息（app/main/依赖落盘路径与体积），供审计与 CI
./target/jstart --quiet info "$app"

# 离线整合：把依赖从 --source 仓库复制到 --local 仓库
./target/jstart repo "$app" --local=/opt/offline-repo
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
