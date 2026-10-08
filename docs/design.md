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

## 进程形态：jstart 如何把自己换成 java

### 最终形态

`run` 结束后进程树里**只有一个进程**：它的 PID 就是启动 jstart 时拿到的那个 PID，
进程本体是 `java`（jar/war）或解压出来的 native 可执行文件（tar.gz）。jstart 不留下
任何痕迹——没有 jstart 父进程、没有 jstart 残留线程、没有它自己写的 pid 文件：

```text
shell / systemd
     │  启动（fork+exec jstart）
     ▼
PID 1234 = jstart ────── execvp() ──────→ PID 1234 = java
  ├─ curl   下载依赖（临时子进程，用完即回收）      PPID 不变，还是启动它的那个 shell
  ├─ tar    解压发行包（临时子进程，用完即回收）    fd / 终端 / cwd / 环境全部继承
  └─ init   引擎准备（war，临时子进程，用完即回收）  kill 与退出码直接作用于它
```

exec 带来的性质，全部继承自 POSIX 的 `execvp`：

- **PID/PPID 不变**：shell 里的 `$!`、systemd 的 `MainPID`、上层工具记下的 pid 指向的
  始终是同一个进程，只是进程从 jstart 变成了 java；
- **标准输入输出、cwd、环境变量、进程组、rlimits 原样保留**：jstart 读过的 stdin 就是
  java 的 stdin，jstart 的终端就是 java 的终端，没有"信号先到 jstart 再转发"这一层；
- **退出码与信号就是应用自己的**：`kill $!` 直接打在 java 上，java 的退出码就是
  `jstart run` 的退出码；
- **没有中间等待者**：不存在"jstart 挂着等 java 退出"，也不存在 jstart 被 OOM killer
  先挑掉、把应用晾成孤儿的情况。

### 如何达到

jstart 是单二进制，没法像 shell 那样"自己退出再换一个程序跑"，所以走 `execvp` 就地
替换。`run` 分三步：

1. **准备阶段（jstart 还是进程本体）**：解析 launch spec → 定位目标、下载缺失依赖
   （宿主 `curl` 子进程，jstart 逐个等待）→ native 目标解压（`tar` 子进程）→ war 目标
   运行 `[engine] init` 命令（子进程，jstart 等它退出后读它写出的
   `<base>/engine-entry.argv`）。这一步里出现的子进程都是短命的，用完即回收；它们
   结束后进程树里只剩 jstart 自己。
2. **组装最终 argv**：
   - jar/解压目录：`java [runtime 参数] -cp <classpath> <Main-Class> [应用参数...]`
   - war：init 命令写进 `engine-entry.argv` 的那条容器启动命令（NUL 分隔 argv，jstart
     只负责读出，不拼装，见 [engine.md](engine.md)）
   - native：`<解压根>/<可执行文件> [应用参数...]`
3. **exec**（`source/jstart/launcher.d` 的 `execCmd`）：把 argv 拷成以 NULL 结尾的
   `char*[]`，flush 掉自己的 stdout/stderr，然后调 `execvp()`。内核就地把当前进程的
   地址空间换成新程序（加载 ELF、重置堆栈、信号处理复位为默认），**PID、打开的文件
   描述符、环境、进程组一律不动**：
   - **成功：`execvp` 永不返回**。从返回点往后 jstart 的代码、堆内存都不存在了，进程
     里跑的就是 java——"jstart 变成 java"就是这一句 syscall 的字面效果；
   - **失败：才返回**，打印 `Cannot execute <cmd>` 并以 **127** 退出（shell 的
     "找不到命令"惯例）。

`--print` 是唯一的例外路径：走到第 2 步后只把 argv 按 POSIX 单引号打印出来就退出
（exit 0），不 exec——它打印的就是第 3 步本要 exec 的那条命令。

代码路径对照：

| 目标 | 最终进程 | 调用链（`source/app.d` → `launcher.d`） |
|------|----------|----------------------------------------|
| jar / 解压目录 | `java -cp ... <Main-Class>` | `runJarApp` → `execCmd` → `execvp` |
| war（引擎） | init 写出的容器命令 | `runProcessCapture(init)` → `parseEntryArgv` → `execCommand` → `execvp` |
| native tar.gz | 解压出的可执行文件 | `runNativeApp` → `execCmd` → `execvp` |
| 任意目标 + `--print` | 不启动，只打印 | `printJavaCommand` / `printCommand`（exit 0） |

### 自己验证

```bash
jstart --verbose run app.jar --port=8080 >app.log 2>&1 &
pid=$!                          # 这一刻 PID 还是 jstart（准备阶段）
grep 'Running java' app.log     # exec 前的最后一条输出，就是分界线
ps -o pid,ppid,comm -p $pid     # PID/PPID 没变，comm 已经是 java
ps -C jstart                    # 只剩表头：进程树里没有 jstart 了
```

### 为什么不用"解析完先退出、再由 shell 执行"

beangle/boot（Scala 版）就是两步：`resolve.sh` 退出 → `launch.sh` 再执行 java，最终
进程自然是 java。jstart 合并成单二进制后没有 shell 在中间串联，若改用
"fork 子进程跑 java、父进程等待"，最终会多出一层无意义的 jstart 父进程：pid 归属、
信号转发、退出码都要多兜一圈。`execvp` 让单二进制拿到与"shell 直接执行"完全相同的
进程形态。

### Windows 例外

Windows 没有等价的 `exec`，`run` 退化为 `spawnProcess + wait`（jstart 作为父进程等待
java 并回传退出码），代码里以 `version (Windows)` 分支隔离；POSIX 上的上述进程形态
不适用于 Windows。

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

### 为什么默认根是 `/var/tmp/jstart`

base 是**可丢弃但要稳定**的运行产物：整个根被清掉也没关系（`.jstart.stamp` 不匹配就重新
解压），但路径要能被上层工具（basctl、systemd 单元、脚本）稳定约定，还要多用户、多组件
共用一个根。候选位置里只有 `/var/tmp` 同时满足：

| 位置 | 为什么不选 / 为什么选 |
|------|----------------------|
| `/tmp` | 常挂 tmpfs：解压体积（包的 2–3 倍）吃内存；常挂 `noexec`：解压出的可执行文件被拒绝执行；`systemd-tmpfiles` 10 天清理、重启即清 |
| `~/.cache/jstart` | 不可共享：服务账号可能没有 home，上层工具也难以推断其他用户的家目录路径 |
| `/var/lib` | 永久状态目录，语义不符——base 是缓存不是权威数据，允许被清理重建 |
| `/var/tmp`（采用） | FHS 规定存放"重启后仍保留的临时数据"：通常是真实磁盘（非 tmpfs）、不挂 `noexec`、清理周期 30 天；目录本身 1777 sticky，各用户可在其中共存 |

**自动创建的范围**：jstart 只创建根本身（`/var/tmp/jstart`，缺省根建成 01777 sticky）与
其中的组件目录（0700，属主校验）；`/var/tmp` 由 FHS 约定、主流发行版都自带，权限与
`/tmp` 相同（1777 sticky），普通用户在其中建子目录不需要 sudo，所以缺省路径开箱即用。
`/var/tmp` 缺失或只读的环境（极简容器、只读 `/var`）**不会静默换地方**，而是报
`Cannot prepare the base root ...` 并提示用 `--base=<dir>` 指定——服务的运行目录悄悄挪进
`/tmp` 只会撞上表中那几个坑；换根建议 `--base=~/.cache/jstart/<应用>`。

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

- **单一本地仓库（重点）**：release/普通构件（含 `.sha1`）与 SNAPSHOT 都落在同一个
  本地仓库（默认 `~/.m2/repository`，`--local=` 覆盖）。SNAPSHOT 的**时间戳**构件
  （`a-1.0-<yyyyMMdd.HHmmss>-<build>.jar`）与 `<a>-<v>-SNAPSHOT.jar` 字面别名同处
  版本目录 `g/a/<v>-SNAPSHOT/`，取用时先选最新时间戳、其次字面别名——采用 maven 原生
  布局，`sbt publishM2`/`mvn install` 的产物无需搬运即可被 jstart 使用。时间戳由构建
  工具以 UTC 生成并编码在文件名里，字符串即时间序：
  解析 `-SNAPSHOT` 别名时按 `--remote` 顺序询问上游——先 HEAD 别名读 micdn 的
  `latest` 响应头，再取版本目录的 `maven-metadata.xml`（`<snapshotVersions>` 按
  extension/classifier 取最新，老式元数据回退 `<snapshot>` 的 timestamp/buildNumber）——
  得到时间戳文件名后落盘到本地仓库；本地已有该时间戳文件且 `.sha1` 通过就不再下载。上游
  都解析不出时退回本地仓库已有的最新时间戳文件，离线可用；不比较本地 mtime 与远端
  Last-Modified。
- 远程列表分两份（`Resolver.remotes` / `Resolver.snapshotRemotes`）：
  - **正式版**：默认阿里云 public → 华为云 maven → Maven Central；`--remote=` 覆盖时
    Central 总会保留在末尾（对齐原版行为）；
  - **SNAPSHOT**：只用 `--snapshot-remote`，**不兜到 `--remote`**，也**不追加 Central、
    不给默认镜像**；不配时本地仓库命中即用（不发请求、不报错），只有本地缺失、需要
    拉取才报错（`--offline` 只是不拉取，语义等同于没配上游）。开发版一般来自专用快照
    仓库，兜到 `--remote`/公共镜像既无必要也会造成"没配快照上游却从公网拉开发版"的意外。
- sha1 语义（对齐原版）：
  - 本地已有 jar 且 `.sha1` 齐全 → 校验，不匹配则删除重下；本地已有但无 `.sha1`
    → 直接接受，不发网络请求（无需下载时忽略校验）；
  - 一旦发生下载（release 与 SNAPSHOT 均如此），从同一远程补拉 `.sha1` 复核，
    不匹配则删除并尝试下一远程；远程无 `.sha1` 时接受（verify aborted）；
  - SNAPSHOT 构件：每次向上游解析最新时间戳文件（`latest` 头或
    `maven-metadata.xml`），落盘到本地仓库的版本目录后从同一远程复核 `.sha1`
    （远程无 `.sha1` 时接受，与 release 语义一致）；本地已有该时间戳文件且校验通过
    则跳过下载。上游解析不出时退回本地仓库最新时间戳文件，最后才下载远端
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
