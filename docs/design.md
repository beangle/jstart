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
| war 引擎 run | `bas.sh` | 运行引擎 init 命令（准备容器环境、写 argv），再 exec 容器；docBase 归引擎（[engine.md](engine.md)） |

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

`run` 以**组件 base** 为单位组织运行期目录。base 根默认 `/var/tmp/jstart`，
`--base=<dir>` 整体替换它；组件目录是 `<根>/<组件键>`（组件键 = target 短名 + 指纹，
本地路径先绝对化）：

```text
<根>/<组件键>/app/             native tar.gz 的解压树（.jstart.stamp 在内，标记匹配即复用）
<根>/<组件键>/webapps/<ctx>/   引擎解压出的 docBase（引擎的 --base 就是组件目录）
<根>/<组件键>/engine-app.classpath 应用依赖 classpath，经 --app-classpath-file 交给 init 命令
<根>/<组件键>/engine-deps.classpath 引擎依赖 classpath，经 --engine-classpath-file 交给 init 命令
<根>/<组件键>/engine-entry.argv init 命令写出的最终启动命令（NUL 分隔 argv）
```

- **jstart 只写运行目录，不管运行中的实例**：exec 之后进程即应用，pid 的记录与停止
  交给调用方（pid 由上层工具自行记录）。要跑多个副本就给每个副本
  一个 base（`--base=<dir>` 换根，或 spec 的 `[app] base`/`[app] instance`），避免共用
  解压/引擎产物目录；
- 解压等可变产物按 base 各存一份（多副本 = 多份解压）；
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
source/jstart/engine.d           war 引擎：init 命令协议常量（argv/classpath/plan 文件名）、
                                 entry-out argv 解析、引擎依赖合并（不内置依赖目录）
source/jstart/spec.d             launch spec：.jstart 后缀识别（本地/http(s)）、ini 解析
                                 （[app]/[runtime]/[args]/[libs]/[engine]/[subapp <id>]）
source/jstart/resolver.d        目标解析、依赖准备、CLASSPATH 装配
source/jstart/consolidate.d     repo 离线整合（复制 jar + .sha1）
source/jstart/native.d          native tar.gz：解压到给定目录（临时目录+改名，支持并发）、
                                 包内可执行文件探测（[app] exec）
source/jstart/base.d            组件 base：目录推导、创建与私有权限校验
source/jstart/launcher.d        exec 入口：java（jar/war）与 native 可执行文件共用 execvp
```

依赖关系：`app.d → spec.d（解析 launch spec）/ resolver / consolidate / distrepo / native / base /
launcher → archive / repo / http / zipfile / bspatch / gzip`。

## 依赖准备流程

launch spec target（`.jstart`，支持本地路径或 http(s) url，见
[launch-spec.md](launch-spec.md)）在进入本流程前由 `app.d` 经 `spec.d` 解析成
"entry + 可选扩展依赖 + 启动参数"：`[libs]` 追加/覆盖在 entry 内置依赖描述之上
（同名 `g:a` 以 `[libs]` 为准，见第 2/3 步）；`[app] main`/`[app] runtime`/`[runtime]`/`[args]`
用于最后一步启动。http(s) spec 先经 `fetchTarget` 下载、按主机路径缓存到本地仓库，
再按本地文件读取解析（repo 是离线整合命令，仍只接受本地 `.jstart`）。

1. **定位应用**（`fetchTarget`）：本地文件/目录直接使用；`g:a:v`/`gav://` 先按 gav
   下载主包；`http(s)` url 按主机路径缓存到本地仓库镜像目录。
2. **读取依赖描述**（`resolveDependencies`）：
   - jar：`META-INF/beangle/dependencies`
   - war：`WEB-INF/classes/META-INF/beangle/dependencies`（缺失时回退 jar 位置）
   - 解压目录：目录下对应 war 路径的文本文件
   - 其它普通文件：不再读取（纯文本依赖清单已不支持，见 commands.md 目标形态）
3. **逐行解析并合并**（`parseDependencyText` + `mergeLibraries`）：空行忽略、重复行
   去重；`[libs]` 先于内置清单，同名 `g:a` 以 `[libs]` 为准，格式见
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
   命令行其余透传参数；启动命令的 java 目前是唯一运行时。war 目标不读 Main-Class，
   且只能从 launch spec 的 `[app] entry` 进入（裸 war 目标由 `run` 直接拒绝；
   `resolve`/`fetch`/`repo` 不受限）：
   解析**必填**的 `[engine] init`（命令行：路径，或“程序 + 参数”；不是 java 类）与
   `[engine]` 其余行（引擎 + 容器 jar 清单，原样解析、无占位符；jstart 不内置依赖目录）
   后，运行 init 命令准备环境，再 exec 它写出的最终命令，见
   [engine.md](engine.md)/[war-engine.md](war-engine.md)。

## 仓库与校验策略

- **本地仓库与快照库分离（重点）**：release/普通构件（含 `.sha1`）落在本地仓库
  （默认 `~/.m2/repository`，`--local=` 覆盖）；SNAPSHOT **时间戳**构件
  （`a-1.0-<yyyyMMdd.HHmmss>-<build>.jar`）只落在**独立的快照库**（默认
  `~/.m2/snapshots`）——repository 内不会出现时间戳文件名，快照库内只放带时间戳的
  文件，二者不混合。时间戳由构建工具以 UTC 生成并编码在文件名里，字符串即时间序：
  解析 `-SNAPSHOT` 别名时按 `--remote` 顺序询问上游——先 HEAD 别名读 micdn 的
  `latest` 响应头，再取版本目录的 `maven-metadata.xml`（`<snapshotVersions>` 按
  extension/classifier 取最新，老式元数据回退 `<snapshot>` 的 timestamp/buildNumber）——
  得到时间戳文件名后落盘到快照库；本地已有该时间戳文件且 `.sha1` 通过就不再下载。上游
  都解析不出时退回本地快照库已有的最新时间戳文件，离线可用；不比较本地 mtime 与远端
  Last-Modified。显式 `--local=<dir>` 时快照时间戳文件也定位到该 base 下的快照路径
  （对齐 boot 显式 base 语义），二者仍按 maven 发布/快照布局区分存放。
- 远程列表分两份（`Resolver.remotes` / `Resolver.snapshotRemotes`）：
  - **正式版**：默认阿里云 public → 华为云 maven → Maven Central；`--remote=` 覆盖时
    Central 总会保留在末尾（对齐原版行为）；
  - **SNAPSHOT**：只用 `--snapshot-remote`，**不兜到 `--remote`**，也**不追加 Central、
    不给默认镜像**；不配时本地快照库命中即用（不发请求、不报错），只有本地缺失、需要
    拉取才报错（`--offline` 只是不拉取，语义等同于没配上游）。开发版一般来自专用快照
    仓库，兜到 `--remote`/公共镜像既无必要也会造成"没配快照上游却从公网拉开发版"的意外。
- sha1 语义（对齐原版）：
  - 本地已有 jar 且 `.sha1` 齐全 → 校验，不匹配则删除重下；本地已有但无 `.sha1`
    → 直接接受，不发网络请求（无需下载时忽略校验）；
  - 一旦发生下载（release 与 SNAPSHOT 均如此），从同一远程补拉 `.sha1` 复核，
    不匹配则删除并尝试下一远程；远程无 `.sha1` 时接受（verify aborted）；
  - SNAPSHOT 构件：每次向上游解析最新时间戳文件（`latest` 头或
    `maven-metadata.xml`），落盘到本地快照库（默认 `~/.m2/snapshots`，`--local`
    显式给定时用该 base，镜像 boot `LocalSnapshot`）后从同一远程复核 `.sha1`
    （远程无 `.sha1` 时接受，与 release 语义一致）；本地已有该时间戳文件且校验通过
    则跳过下载。上游解析不出时退回本地快照库最新时间戳文件，最后才下载远端
    `-SNAPSHOT` 字面文件。
- 下载统一走宿主 `curl` 命令：`--fail --silent --show-error -L`，先写同目录
  `.name.part` 临时文件再 rename，避免跨设备移动与半截文件；多依赖下载默认并发
  （`--jobs=N`，默认 10，`1` 为串行），每个依赖各自独立 curl 进程；远端支持 Range
  且文件 ≥1MB 时，单文件按最多 4 段并行下载（`curl -r`）后按序合并，失败回退
  单请求。

## 约束与取舍

- **不解析传递依赖**：依赖描述文件是唯一来源，只逐行处理显式依赖（见流程第 3 步），
  不读 POM、不展开传递依赖；全部运行期依赖须由构建期插件写全，漏写以 Missing 失败。
- `run` jar 目标支持带 `Main-Class` 的瘦 jar；war 目标须由 launch spec 声明
  （`[app] entry`）并**显式声明引擎**（`[engine] init`）后走引擎流程：
  jstart 运行 init 命令准备环境、再 exec 容器，docBase 布局与解压都归引擎；jstart
  不内置 tomcat/undertow 依赖目录（引擎中立），引擎 + 容器 jar 由 `[engine]` 段写全。
  entry 是已解压 webapp 目录时同样声明 `[engine] init` 走引擎（直接用该目录，不解压）；
  可执行 war（自带 Main-Class）不支持。
- 并发粒度："跨依赖"由 `--jobs` 控制，单文件 Range 分段由远端支持与文件大小自动
  决定（≥1MB 最多 4 段）；`fetch` 支持 bsdiff 增量补丁（native tar.gz 解压后比对、
  jar/war 直接比对，见 [commands.md](commands.md)），但**不做跨次运行的断点续传**。
- 以 Java 工件为主，同时支持 native 发行包：`run` 的终点是 java（jar 走 `Main-Class`，
  war 走 spec 声明的引擎）或解压出的 native 可执行文件（tar.gz）；两者共用同一个 exec 入口，
  launch spec 用通用运行时命名，其他运行时（python3/node 等）仍可继续扩展但尚未实现。
