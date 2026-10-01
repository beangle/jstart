# 设计思路

jstart 借鉴 beangle/boot 的思路，用 D 语言实现为**单原生二进制**：不需要 JVM 参与解析阶段，
最终以 exec 方式把控制权交给应用进程。

## 与 beangle/boot 的对应关系

原 Scala 项目把"解析"与"执行"拆成两步，由 shell 串联：

```text
resolve.sh（AppResolver → 下载依赖 → 应用路径）
    ↓
launcher.Classpath（Main-Class@classpath）
    ↓
java -cp ... Main-Class args          # 由 launch.sh 直接执行
```

jstart 用四个子命令覆盖同一职责：

| jstart | 原 boot 组件 | 作用 |
|--------|--------------|------|
| `resolve` | `dependency.AppResolver` | 解析目标、下载缺失依赖、输出应用路径 |
| `classpath` | `launcher.Classpath` | 输出 `Main-Class@classpath` |
| `repo` | `launcher.Repo` | 离线仓库整合（复制缺失构件） |
| `run` | `resolve.sh` + `launch.sh` | 准备环境后 exec 成 java |
| war 引擎 run | `sas.sh` | 解压 war 到 `<base>/webapps/<ctx>`，exec `org.beangle.sas.engine.<name>.Bootstrap`（[war-engine.md](war-engine.md)） |

保留 `resolve`/`classpath` 是为了兼容 launch.sh 式的脚本解耦；`run` 则把两步合并进
单个进程。

## 为什么用 exec

beangle/boot 的做法是"解析进程退出，shell 再执行 java"，最终进程就是 java、没有多余
的父子等待关系。jstart 是单二进制，无法像 shell 那样先退出再执行，因此 `run` 在解析
完成后调用 `execvp` **用 java 替换自身进程**：

- 最终进程仍是 `java`（同一 PID），父进程就是启动 jstart 的 shell；
- 退出码、信号、stdin/stdout/stderr 行为与直接运行 java 完全一致；
- 解析器在 exec 后不再存活，不存在"jstart 挂着等 java"的问题。

Windows 没有等价的 `exec`，`run` 退化为 `spawnProcess + wait`（子进程方式），代码中
已用 `version (Windows)` 分支注明。

## 运行期目录：组件 base

`run`/`stop` 以**组件 base** 为单位组织运行期目录。base 根默认 `/var/tmp/jstart`，
`--base=<dir>` 整体替换它；组件目录是 `<根>/<组件键>`（组件键 = target 短名 + 指纹，
本地路径先绝对化）：

```text
<根>/<组件键>/app.pid          run 在 exec 前写、stop 读（实例是否在跑就靠它）
<根>/<组件键>/app/             native tar.gz 的解压树（.jstart.stamp 在内，标记匹配即复用）
<根>/<组件键>/webapps/<ctx>/   war 的解压目录（引擎的 --base 就是组件目录）
```

- **实例身份 = 组件 + base，与应用参数无关**：一个 base 只能跑一个实例，重复 `run` 会被
  拒绝（exit 1，`--force` 可覆盖）；要跑多个副本就给每个副本一个 base
  （`--base=<dir>`、`--instance=<name>` 或 spec `[app] base`）；
- `stop` 只需要组件与 base，因此**不需要重复 run 时的参数**，也不需要取包或解析依赖；
- 解压等可变产物按 base 各存一份（多副本 = 多份解压），换来的是身份简单、run/stop
  一致：base 对上就是同一个实例；
- 解压仍先写独立临时目录、再整体 `rename` 就位，旧目录改名挪走后清理，正在运行的实例
  继续用旧 inode，所以并发启动或强杀残留都不会看到半个目录。

## 模块架构

```text
source/app.d                    命令入口与参数解析
source/jstart/archive.d         依赖模型：Artifact/LocalFile/RemoteFile、gav、Maven2 布局
source/jstart/repo.d            本地仓库 LocalRepo、远程仓库列表、sha1 工具
source/jstart/http.d            调用宿主 curl 下载（仿 micdn）
source/jstart/distrepo.d        发行仓库取包：gav 布局/快照命中、增量补丁探测与重建、基线推断
source/jstart/bspatch.d         BSDIFF40 内置实现；宿主 bspatch 优先，失败/缺失时回退
source/jstart/gzip.d            增量重建 tar.gz 用的 gunzip/gzip（gzip -n -6，走宿主命令）
source/jstart/zipfile.d         jar/war 条目读取（zip-slip 防护的解压）、Manifest Main-Class 解析
source/jstart/mainclass.d       主类决策：--main > [app] main > jar manifest（纯函数，可单测）
source/jstart/engine.d           war 引擎：主类映射、内置默认依赖目录（tomcat/undertow，
                                 tomcat 可带版本后缀）、解压布局/参数扫描、[engine] 行占位符展开
source/jstart/spec.d             launch spec：.jstart 后缀识别（本地/http(s)）、ini 解析
                                 （[app]/[runtime]/[args]/[deps]/[engine]，通用运行时命名）
source/jstart/resolver.d        目标解析、依赖准备、CLASSPATH 装配
source/jstart/consolidate.d     repo 离线整合（复制 jar + .sha1）
source/jstart/native.d          native tar.gz：解压到给定目录（临时目录+改名，支持并发）、
                                 包内可执行文件探测（[app] exec）
source/jstart/base.d            组件 base：pid 文件、重复启动检测、stop（SIGTERM/SIGKILL）
source/jstart/launcher.d        exec 入口：java（jar/war）与 native 可执行文件共用 execvp
```

依赖关系：`app.d → spec.d（解析 launch spec）/ resolver / consolidate / distrepo / native / base /
launcher → archive / repo / http / zipfile / bspatch / gzip`。

## 依赖准备流程

launch spec target（`.jstart`，支持本地路径或 http(s) url，见
[launch-spec.md](launch-spec.md)）在进入本流程前由 `app.d` 经 `spec.d` 解析成
"entry + 可选显式依赖 + 启动参数"：`[deps]` 存在时它是依赖唯一来源（跳过第 2 步的
内置清单），否则 entry 仍走内置依赖描述；`[app] main`/`[app] runtime`/`[runtime]`/`[args]`
用于最后一步启动。http(s) spec 先经 `fetchTarget` 下载、按主机路径缓存到本地仓库，
再按本地文件读取解析（repo 是离线整合命令，仍只接受本地 `.jstart`）。

1. **定位应用**（`fetchTarget`）：本地文件/目录直接使用；`g:a:v`/`gav://` 先按 gav
   下载主包；`http(s)` url 按主机路径缓存到本地仓库镜像目录。
2. **读取依赖描述**（`resolveDependencies`）：
   - jar：`META-INF/beangle/dependencies`
   - war：`WEB-INF/classes/META-INF/beangle/dependencies`（缺失时回退 jar 位置）
   - 解压目录：目录下对应 war 路径的文本文件
   - 其它普通文件：不再读取（纯文本依赖清单已不支持，见 commands.md 目标形态）
3. **逐行解析**（`parseDependencyText`）：空行忽略、重复行去重，格式见
   [dependencies.md](dependencies.md)。
4. **下载校验**（`ensureArtifact`/`ensureRemoteFile`）：本地已有则用 `.sha1` 校验，
   缺失/损坏按远程顺序逐个下载；同远程再取 `.sha1` 复核，不匹配删除并尝试下一远程。
5. **装配**（`buildClasspath`）：应用 jar（或解压 war 的 `WEB-INF/classes`+`WEB-INF/lib`）
   在前，依赖在后，`CLASSPATH_EXTRA`/`classpath_extra` 前置。
6. **执行**（`run`）：定主类（`--main` > spec `[app] main` > Manifest `Main-Class`，
   见 `jstart.mainclass`；都没有则报错提示 `--main=<class>`），exec 为
   `java <runtime-options> -cp <cp> <Main-Class> [app-args...]`。运行时可执行文件取
   spec `[app] runtime`（缺省 `$JAVA_HOME`/PATH 的 java，JVM 家目录自动补 `bin/java`），
   运行时参数取 `[runtime]` 段与命令行 `-D`/`-X` 追加，应用参数取 `[args]` 段与
   命令行其余透传参数；启动命令的 java 目前是唯一运行时。war 目标不读 Main-Class：
   解析（可选）`[app] engine`（tomcat 可带版本后缀，如 `tomcat-11.0.24`）与
   `[engine]` 段（行内 `{tomcat.version}`/`{sas.version}` 占位符先展开；段存在即为
   权威，否则回退内置默认目录）后，解压 war 到 `<base>/webapps/<ctx>` 并 exec 引擎
   Bootstrap，见 [war-engine.md](war-engine.md)。

## 仓库与校验策略

- **本地仓库与快照库分离（重点）**：release/普通构件（含 `.sha1`）落在本地仓库
  （默认 `~/.m2/repository`，`--local=` 覆盖）；SNAPSHOT **时间戳**构件
  （`a-1.0-<yyyyMMdd.HHmmss>-<build>.jar`）只落在**独立的快照库**（默认
  `~/.m2/snapshots`）——repository 内不会出现时间戳文件名，快照库内只放带时间戳的
  文件，二者不混合。时间戳由构建工具以 UTC 生成并编码在文件名里，“是否最新”看本地
  时间戳文件名即可（字符串即时间序）：**不比较本地 mtime 与远端 Last-Modified，也
  不解析远端 `maven-metadata.xml`**。显式 `--local=<dir>` 时快照时间戳文件也定位到该
  base 下的快照路径（对齐 boot 显式 base 语义），二者仍按 maven 发布/快照布局区分
  存放。
- 远程默认顺序：阿里云 public → 华为云 maven → Maven Central；`--remote=` 覆盖时
  Central 总会保留在末尾（对齐原版行为）。
- sha1 语义（对齐原版）：
  - 本地已有 jar 且 `.sha1` 齐全 → 校验，不匹配则删除重下；本地已有但无 `.sha1`
    → 直接接受，不发网络请求（无需下载时忽略校验）；
  - 一旦发生下载（release 与 SNAPSHOT 均如此），从同一远程补拉 `.sha1` 复核，
    不匹配则删除并尝试下一远程；远程无 `.sha1` 时接受（verify aborted）；
  - SNAPSHOT 构件：优先本地快照库（默认 `~/.m2/snapshots`，`--local` 显式给定时
    用该 base，镜像 boot `LocalSnapshot`）中最新时间戳构建；没有则下载远端
    `-SNAPSHOT` 字面文件；下载后同样从同一远程复核 `.sha1`（远程无 `.sha1`
    时接受，与 release 语义一致）。
- 下载统一走宿主 `curl` 命令：`--fail --silent --show-error -L`，先写同目录
  `.name.part` 临时文件再 rename，避免跨设备移动与半截文件；多依赖下载默认并发
  （`--jobs=N`，默认 10，`1` 为串行），每个依赖各自独立 curl 进程；远端支持 Range
  且文件 ≥1MB 时，单文件按最多 4 段并行下载（`curl -r`）后按序合并，失败回退
  单请求。

## 约束与取舍

- **不解析传递依赖**：依赖描述文件是唯一来源，只逐行处理显式依赖（见流程第 3 步），
  不读 POM、不展开传递依赖；全部运行期依赖须由构建期插件写全，漏写以 Missing 失败。
- `run` jar 目标支持带 `Main-Class` 的瘦 jar；war 目标走内置引擎（对应 beangle sas
  `sas.sh`）：解压到 `<base>/webapps/<ctx>` 后 exec 引擎 Bootstrap，tomcat/undertow
  都有内置默认依赖目录、可被 launch spec `[engine]` 段显式罗列覆盖（详见
  [war-engine.md](war-engine.md)）；可执行 war（自带 Main-Class）与"解压目录目标走
  引擎"暂不支持。
- 并发粒度："跨依赖"由 `--jobs` 控制，单文件 Range 分段由远端支持与文件大小自动
  决定（≥1MB 最多 4 段）；不做跨次运行的断点续传，也不实现 boot 的 `.diff`
  增量补丁（按取舍决定）。
- 以 Java 工件为主，同时支持 native 发行包：`run` 的终点是 java（jar 走 `Main-Class`，
  war 走内置引擎）或解压出的 native 可执行文件（tar.gz）；两者共用同一个 exec 入口，
  launch spec 用通用运行时命名，其他运行时（python3/node 等）仍可继续扩展但尚未实现。
