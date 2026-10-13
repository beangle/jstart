# Release v0.0.3

发布日期：2026-10-13（v0.0.2：2026-10-09；v0.0.1：2026-09-07）

覆盖 v0.0.1 → v0.0.3 的全部变化。功能主体在 **v0.0.2**（30 个提交，47 个文件
+7991/−1251），**v0.0.3** 只做 README 精简。主线：war 引擎协议改为声明式
`[engine] init` 脚本并保持引擎中立、多 webapp 上线、`fetch` 与 GraalVM native
发行包、SNAPSHOT 并入单一本地仓库、`[deps]` → `[libs]`、输出节制与"每个下载 url
一行"的下载日志。

## 相对 v0.0.1 的变化

### 命令与选项

- **新增 `fetch`**：统一取包命令——gav 从发行仓库取 native tar.gz/jar/war（本地有基线且
  远端有 bsdiff 补丁时只下补丁，否则整包），`http(s)` url 直接下载并按主机路径缓存到
  本地仓库，本地文件原样返回路径；默认发行仓库 `https://sas.openurp.net/native`
  （micdn 的 `/native`），仓库配 `<auth download-key>` 时用环境变量 `micdn_token` 带
  `Authorization: Bearer`（HEAD 探测保持匿名）。
- **新增 `--verbose`/`-v`**：输出解析、下载开始、将执行的启动命令与 init 命令的
  stdout 等过程细节（默认只输出告警/错误与命令结果）。
- **新增 `--offline`**：只用本地仓库——不探测、不下载（SNAPSHOT 也不查 `latest`/
  `maven-metadata.xml`），缺件直接失败。
- **新增 `--snapshot-remote=<urls>`**：SNAPSHOT 专用上游，**不兜到 `--remote`**、
  不追加默认镜像与 Central；不配时本地命中即用（不发请求、不报错），本地缺失、需要
  拉取才报错。
- **新增 `--base=<dir>`、`--main=<class>`、`--from=<version>`**：组件 base 根目录、
  覆盖 java 主类（优先于 `[app] main` 与 jar 的 `MANIFEST.MF`）、增量补丁基线版本。
- **移除 `--preferwar`**：gav 目标的打包类型以 4/5 段显式格式为准（`g:a:v` 即 jar，
  `g:a:war:v` 即 war）。
- **`--quiet` 语义收紧**：由"suppress info output"改为在默认之上再关闭告警与每 url
  一行的下载日志（错误仍由退出码体现）；与 `--verbose` 同给时 `--quiet` 生效。
- **包版本改由 git tag 决定**：deb/rpm 的版本号不再 `awk` 解析 dub.json 的
  `version` 字段，改用 `git describe --tags`（去 `v` 前缀）；取不到 tag 时打印诊断并
  退出 1，不再自己咽掉原因。dub.json 不再写 `version`。

### war 引擎（协议重做）

- **引擎入口改为 `[engine] init` 脚本**：v0.0.1 是"`[app] engine = tomcat/undertow` 选
  内置别名 → exec `org.beangle.sas.engine.<name>.Bootstrap`、内置默认依赖目录、war 由
  jstart 自己爆炸"；现在 jstart 不做别名/FQCN 映射、不内置入口类与依赖清单，由
  `[engine] init = <脚本或可执行文件>`（`~`/`${VAR}` 展开）准备容器环境，它把最终 argv
  （NUL 分隔）写入 `--entry-out`，jstart 再 exec；war 解压与 docBase 归脚本。命令行参数：
  `--base` `--entry` `--engine-classpath-file` `--app-classpath-file`
  `--local-repo` `--entry-out` `[--app-jvm-arg=…]` 与透传参数，协议见
  [engine.md](engine.md)。
- **`init` 支持命令行形式**：取值按 shell 风格分词（空白分隔、单/双引号成组、`\`
  转义，**不经过 shell**，无管道/重定向/通配符），逐 token 做 `~`/`${VAR}` 展开，
  路径按绝对路径/`PATH` 解析、其余保留为参数。`init = engine-creator tomcat-server`
  这类写法无需 wrapper；`init = <路径>` 的旧写法完全兼容。
- **移除内置引擎依赖目录**：不再内置 tomcat/undertow/Dist 的 jar 清单，引擎与容器 jar
  由 `[engine]` 段逐行列出（gav/本地文件/远程 url，同 `[libs]` 语法），**不再支持
  `{tomcat.version}` 之类的占位符**；缺 `[engine]` 或缺 `init` 报错并提示补全。
- **classpath 改由文件传递**：jstart 写 `<base>/engine-deps.classpath` 与
  `<base>/engine-app.classpath`，init 脚本用对应参数读取，避免命令行过长；脚本写出的
  命令过长时折叠成 java 参数文件（`java @<file>`）。
- **启动模型 `LaunchType`**：按解析结果给每个目标派生 `app`（直接 exec 运行时）或
  `engine`（先跑 init 再 exec），判定只看是否声明了引擎，不再从 war 后缀反推；`info`
  输出 `type:`/`engine init:`/`entry type:`。
- **引擎坐标改为 `org.beangle.bas:beangle-bas-engine`**；`[app] main` 与 `[engine]`
  段互斥，同时声明直接报错。
- **war 测试自带最小 creator**：`test/engine-init-stub.sh` 充当 `[engine] init`
  （演示协议本身），不再假定外部引擎工具；`test/war-run-test.sh` 对齐
  beangle-sas-engine 0.14.0。

### 多 webapp

- **`[subapp <id>]` 段**（开发版曾用 `[webapp <id>]`）：单个 spec 声明多个 webapp
  （`entry`/`path`，可选 `libs`），同一 JVM 内各建一个 context；jstart 逐个取回 war
  并把各自依赖补齐到本地仓库（运行时由各 Context 自己的 `DependencyClassLoader` 按
  war 清单解析，不合并进同一 classpath）。
- **交付文件是 launch spec 片段** `<base>/engine-subapps.jstart`（一段一个
  `[subapp <id>]`，含 entry/path/libs），init 脚本按 `--base` 从约定路径读取，**不经
  命令行传递**（此前的 `<base>/engine-webapps.tsv` 方案已废弃）。
- **`[subapp] libs`**：per-webapp 扩展依赖（gav，追加在 war 清单之上，同名以 libs
  为准，对齐 bas `Webapp libs`）。
- `resolve`/`info` 按 webapp 逐个输出；`classpath` 对多应用明确拒绝（exit 2）。

### 依赖与仓库

- **SNAPSHOT 与正式版统一到单一本地仓库**：去掉独立快照库 `~/.m2/snapshots`，
  SNAPSHOT 时间戳构件与 `-SNAPSHOT` 字面别名都落在 `~/.m2/repository/g/a/<version>-SNAPSHOT/`
  版本目录（取用时先选最新时间戳、其次字面别名）。`sbt publishM2`/`mvn install`
  产出的 SNAPSHOT 直接可用，也与其他 maven 工具看到的一致；`repo` 离线整合现在同样
  覆盖 SNAPSHOT。
- **`[deps]` 段改名 `[libs]`，语义改为追加/覆盖**：不再"存在即替换 entry 内置清单"，
  而是追加在内置清单之上；按 `groupId:artifactId` 判同名（不看版本/打包/classifier），
  同名取 `[libs]` 的那条、内置同名项整条丢弃。旧名 `[deps]` 仍可用（告警提示改名）。
- **输出节制**：`--verbose` 追加过程细节、`--quiet` 关闭告警与下载日志；帮助与告警
  文案统一为英文并精简。
- **每个下载 url 一行下载日志**：`<label> Downloaded <url> (N bytes, Ns)`（失败
  `Download failed <url> …`）默认就打到 **stderr**，`--quiet` 关闭，`--verbose` 另给
  `Downloading <url>` 开始行；日志由 jstart 自己打印，curl 保持
  `--fail --silent --show-error`（不输出进度条）。stdout 只留命令结果，
  `app=$(jstart resolve x 2>/dev/null)` 仍是纯路径；`.sha1` 等附属下载不打行，
  一个构件一行。

### fetch 与 native 发行包

- **GraalVM native（tar.gz）目标**：`resolve`/`run` 复用 `fetch` 的取包逻辑（gav 含
  增量补丁）→ 解压到 `<base 根>/<组件键>/app` → exec 包内可执行文件，参数按序附加。
  发行包侧不做快照元数据解析（`-SNAPSHOT` 只当字面版本名）。
- **增量补丁（bsdiff）**：远端有 `<old>_<new>` 补丁时只下补丁重建并复核 `.sha1`，
  没有补丁是正常情况、静默回退整包。tar.gz 按"本地基线 `gunzip` → bspatch →
  `gzip -n -6`"比对解压后的 tar，jar/war 直接比对；打补丁优先系统 `bspatch`
  （失败自动回退内置实现，`JSTART_BSPATCH` 可指定或强制内置）。
- **组件 base**：`--base=<dir>` 换 base 根（默认 `/var/tmp/jstart`），launch spec 可用
  `[app] base` 固定根、`[app] instance = <name>` 显式命名组件目录（`<根>/<name>`，
  不拼指纹）；native 解压、war 解压与引擎产物都在其下。组件目录建完即收紧到 `0700`，
  告警措辞是"组/其他人可写"而非"可读"。jstart 不写 pid 文件、不记录也不停止实例，
  实例身份与停止交给调用方。

### 工程、打包与测试

- **新增源码模块**：`base.d`（组件键/base 推导与权限）、`distrepo.d`（发行仓库与增量
  补丁）、`native.d`（tar.gz 取包/解压/定位可执行文件）、`snapshot.d`（SNAPSHOT 解析
  独立成模块）、`bspatch.d`/`gzip.d`（内置补丁与压缩）、`mainclass.d`（主类解析）。
- **体积**（`dub build --build=release-nobounds --compiler=ldc2`，v0.0.1 与 v0.0.3
  同参数实测）：599KB → 1200KB，`strip` 后 452KB → 886KB——功能与模块增加所致。
- **测试**：新增单测模块 `args`/`base`/`fetch`/`mainclass`/`native`/`snapshot` 与
  `test/engine-init-stub.sh`；`test/smoke.sh` 扩充 544 行（多 webapp、native、增量
  补丁、下载日志、`[libs]` 合并等端到端用例）；`dub test` 15 个模块全绿。
- **打包脚本**：包版本取 git tag（兼容 CentOS 7 的 git 1.8.3，不用 `git -C`）、RPM
  `%changelog` 只收已发布条目且不再吞掉 git 报错。
- **文档**：新增 [engine.md](engine.md)（引擎 init 协议）；`commands.md`/`design.md`/
  `launch-spec.md`/`war-engine.md`/`offline.md`/`build.md` 同步；README 在 v0.0.3
  精简为 Features / Quick start / Build / Docs 四段，细节移交 `docs/`。

## 破坏性变更与迁移（0.0.1 → 0.0.3）

| v0.0.1 | v0.0.2+ | 迁移 |
|--------|---------|------|
| `[deps]` 段 | `[libs]` 段 | 旧名仍可用但告警；语义变为"追加/覆盖"，同名以 `[libs]` 为准 |
| `[app] engine = tomcat/undertow`（内置别名 + 默认依赖目录 + `{x.version}` 占位符），jstart 爆炸 war 并 exec `org.beangle.sas.engine.<name>.Bootstrap` | `[engine] init = <脚本>` + `[engine]` 逐行列依赖（引擎中立，无别名/清单/占位符），解压与 docBase 归脚本 | 引擎侧按 [engine.md](engine.md) 协议改造；引擎坐标改为 `org.beangle.bas:beangle-bas-engine` |
| `~/.m2/snapshots` 独立快照库 | 并入 `~/.m2/repository` 的版本目录 | 旧快照库需手工迁移或让 jstart 重新下载 |
| `--preferwar` | 移除 | gav 用 4/5 段显式 packaging/classifier |
| `--quiet` = suppress info | `--quiet` = 关告警与下载日志 | 只要路径/结果仍用 `--quiet`；要过程细节用 `--verbose` |
| 默认 stdout 只有告警与结果 | 默认另有每 url 一行下载日志（**stderr**） | 脚本捕获 stdout 不受影响；要静音加 `--quiet` |

## 分版本

- **v0.0.2（2026-10-09）**：上述全部功能与迁移项，30 个提交。
- **v0.0.3（2026-10-13）**：README 精简——由长特性清单压缩为 Features/Quick start/
  Build and test/Docs 四段（−116/+70 行），细节移交 `docs/`。

## 已知限制

- 不做传递依赖解析（项目约束）：依赖描述是唯一来源，运行期依赖须构建期写全。
- 无跨次运行的断点续传；增量补丁覆盖 native tar.gz（解压后比对）与 jar/war（直接
  比对），zip/ear 等不实现。
- SNAPSHOT 每次解析仍先探测上游（micdn 的 `latest` 头，其次 `maven-metadata.xml`），
  离线机器会多一次网络尝试（失败退回本地文件，不影响使用）。
- 下载进度条**明确不做**：只有一行/URL 的结果日志（`--quiet` 关），curl 保持静默。
- war 作为 `run` 目标必须写进 launch spec（`[app] entry`）；可执行 war（自带
  `Main-Class`）与"解压目录走引擎"暂不支持。`[app] runtime` 取非 java 值仅为结构预留。
- Windows `run` 无 exec 语义（`spawnProcess + wait`），退出码可传播但进程关系不同。
- 依赖描述行的 `g:a:v` 含 `-` 分隔 classifier 等非常规写法时，请用 4/5 段显式格式。
- **v0.0.2/v0.0.3 的 `-V` 打印 `0.0.1`**：版本取自 `source/app.d` 的 `jstartVersion`
  常量，要按发布核对单（[build.md](build.md)）在打 tag 前手工同步；这两个版本漏了同步
  （包版本走 git tag，deb/rpm 号不受影响）。develop 已同步为 `0.0.3`，后续宜让打包
  脚本校验常量与 tag 一致、漏同步直接失败。

## 路线图

- 跨次运行断点续传。
- 打包脚本校验 `jstartVersion` 与 git tag 一致（避免再漏同步 `-V`）。
- Windows 原生支持与 launch.bat 式脚本入口。
