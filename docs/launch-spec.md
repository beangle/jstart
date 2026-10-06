# Launch Spec：启动说明文件

`run` 的另一种输入形态：一个类似 ini 的文本文件，声明"启动一个应用"所需的一切——
Java 主类（main）、应用本体来源（entry）、运行时/解释器（runtime）及其参数、
应用参数与依赖清单。它解决现有两个场景缺口：

- 只有依赖无法启动：依赖清单要么随应用本体内置（jar/war），要么由 launch spec
  携带；spec 在清单基础上把 main/entry 显式声明出来；
- 应用"怎么启动"（含 `--port=8080` 这类参数、运行时参数）从散落的命令行/脚本收敛为
  一份可提交、可评审、可复用的文件——`run` 的声明式目标就是 launch spec。

> spec 用 `runtime` 这类通用命名是为让 JDK 可替换（而不是绑定某个 java 路径），也避免文件
> 格式绑定 Java 术语，从而保留接入其他运行时的扩展能力。当前以 Java（jar/war）为主，
> 另支持 GraalVM native 发行包（tar.gz）：entry 指向 tar.gz 时没有 JVM，用 `[app] exec`
> 指定包内可执行文件（见下文）。取 java 之外的值（如 `python3`、`node`）仍仅为结构与文档预留。

## 文件识别

- 命令行 target 为 launch spec 时**必须以 `.jstart` 结尾**：本地路径
  `/path/app.jstart` 或 `http(s)://host/path/app.jstart` 均可。http(s) spec 先
  下载并缓存到本地仓库（按主机路径缓存，与远程 jar 一致），再按本地文件解析；
- 其它后缀、以及"内容看起来像 ini/段头"的普通文本文件**都不再**判定为 spec——
  普通文本文件**不支持**为依赖清单 target（依赖清单只来自 jar/war 内置描述或
  本文件的 `[libs]` 段）。

> 远程 spec 与远程 jar 一样按主机路径缓存、无过期判定：要取更新版请清理本地仓库
> 对应缓存条目（或换一个 url）。

## 格式

```ini
# jstart launch spec（# 或 ; 开头为注释）
[app]
main = org.beangle.app.Main            # 可选（Java）：主类全名；缺省回退 Manifest Main-Class
entry = gav://org.beangle:app:0.0.1    # 必填：gav | gav:// | http(s):// | 本地文件/目录
runtime = /opt/jdk21/bin/java          # 可选：运行时/解释器可执行文件；支持 ~ 与 ${VAR}
working_dir = ${APP_HOME}              # 可选：启动前 chdir；支持 ~ 与 ${VAR} 展开
base = /srv/jstart                     # 可选：base 根目录（替换缺省 /var/tmp/jstart）
instance = portal-a                    # 可选：显式组件目录名（<base 根>/<instance>，不拼指纹）

[runtime]
-Xmx512m                               # 每行一个运行时参数，原样拼接（不做 shell 切分）
-XX:+UseG1GC
-Dfile.encoding=UTF-8

[args]
--port=8080                            # 每行一个应用参数，原样作为单个 argv（不做 shell 切分）
--path=/base

[libs]
com.zaxxer:HikariCP:7.0.3              # 可选段：扩展依赖，追加/覆盖在 entry 内置清单之上
org.slf4j:slf4j-api:2.0.17
```

### native（tar.gz）entry

entry 指向 GraalVM native 发行包（gav 的 `tar.gz` 打包，或本地 `*.tar.gz`）时，
jstart 取包（gav 走 `fetch` 的发行仓库逻辑，含增量补丁）→ 解压到 `<base>/app`（base =
`<base 根>/<组件键>`，根默认 `/var/tmp/jstart`，可用 `--base`/`[app] base` 换）→ exec 包内可执行文件，
`[args]` 与命令行参数按序附加在其后。此时没有 JVM：`[runtime]` 段与
`[app] runtime` 会被告警忽略，`[app] main` 无意义，可执行文件位置用 `[app] exec` 声明
（相对解压根目录；缺省按 `<name>/bin/<exe>` 探测）。native 侧**不对 `-SNAPSHOT` 特殊
照顾**：`entry` 里的 `-SNAPSHOT` 只当字面版本名，不做快照元数据探测，走本地命中 →
增量补丁 → 整包下载：

```ini
# beangle-ems-portal.jstart：native 发行包
[app]
entry = org.beangle.ems:beangle-ems-portal:tar.gz:linux-amd64:4.20.14-SNAPSHOT
exec = beangle-ems-portal-4.20.14/bin/beangle-ems-portal
working_dir = ${APP_HOME}

[args]
--port=8080

[libs]                                 # 可选：native 包内没有依赖清单，需要时在此显式罗列
```

### 段与键

| 段 | 键/内容 | 说明 |
|----|---------|------|
| `[app]` | `base` | 可选。base 根目录，替换缺省的 `/var/tmp/jstart`；组件的运行目录是 `<base>/<组件键>`（pid 文件、native 解压、war 解压都在其下），`run`/`stop` 用同一个 base 找实例（见 [commands.md](commands.md)） |
| `[app]` | `instance` | 可选。显式组件目录名：给了就是 `<base 根>/<instance>`（不再拼 target 指纹），限单个安全路径段（`[A-Za-z0-9._-]`，不能是 `.`/`..`）。没有命令行选项；`run`/`stop` 都从 spec 读，所以实例的 spec 要保留（见 [commands.md](commands.md)） |
| `[app]` | `main` | 可选（Java）。主类全名，命令行 `--main=<class>` 优先于本键。缺省时回退：entry 为 jar 时读其 Manifest `Main-Class`；仍无则 run 报错（war/native 目标不需要主类，见下）。**与 `[engine]` 段互斥**，同时出现直接报错 |
| | `entry` | 必填。取值同现有 target：`g:a:v`/`gav://`、native 的 `g:a:tar.gz:<classifier>:v`、`http(s)://`、本地 jar/war/tar.gz/解压目录/文件路径 |
| | `working_dir` | 可选。exec 前切换工作目录，沿用 `~`/`${VAR}` 展开 |
| | `runtime` | 可选。运行时/解释器可执行文件（`java`/`python3`/`node`/...）或 java 安装目录（自动补 `bin/java`）；支持 `~`/`${VAR}` 展开；缺省按 entry 推断（jar → `$JAVA_HOME`/PATH 的 java） |
| | `exec` | 可选（native tar.gz）。包内可执行文件，**相对解压根目录**（如 `demo-1.0/bin/demo`）；缺省自动探测 `<name>/bin/<exe>` 或唯一可执行文件；jar/war entry 忽略此键 |
| | | （`[app] engine` 已移除：引擎入口改用 `[engine] init`；写了会被告警忽略） |
| `[runtime]` | 行列表 | 每个非注释行是一个运行时参数（Java 的 `-D`/`-X`/`--add-opens`、Python 的 `-O` 等），按书写顺序拼接；native（tar.gz）目标无 JVM，该段告警忽略 |
| `[args]` | 行列表 | 每个非注释行是一个应用参数，**整行**作为一个 argv：不切分、不展开变量，值含空格可直接书写；native 目标同样附加在可执行文件之后 |
| `[libs]` | 行列表 | 可选。**扩展依赖**：每行与依赖描述文件同语法（gav/本地文件/远程 url），一行也可逗号分隔多个 gav。**追加/覆盖**在 entry 内置清单之上（同名 `g:a` 以本段为准）；native 无清单时即为全部依赖。旧名 `[deps]` 仍可用（告警并按 `[libs]` 处理），已废弃 |
| `[engine]` | `init` + 行列表 | 声明引擎时**必填**（war/目录与多应用）。`init = <路径|命令>` 是引擎 init 命令（最简是可执行文件/脚本路径，也可带参数；`~`/`${VAR}` 展开，不是 java 类）；其余行是引擎启动器依赖，语法同 `[libs]`（gav/本地文件/远程 url），**原样解析、无占位符**。jstart 不内置任何依赖目录，容器 jar 也由用户写全（见 [engine.md](engine.md)） |
| `[subapp <id>]` | `entry` / `path` / `libs` | 可选、可重复。**多应用**：一个引擎在同一 JVM 里跑多个 webapp，每个一段；`entry` 同 `[app] entry`，`path` 是该 webapp 的上下文路径（归一化后各自唯一），`libs` 是该 webapp 的扩展依赖（gav，一行可逗号分隔多个，可不写）。与 `[app] entry`/`main`/`[libs]` 互斥，且必须配合 `[engine] init`（见下） |

### 语义约定

- `[libs]` 是**扩展依赖**，**追加/覆盖**在 entry 内置清单之上，规则如下：

  | 项 | 规则 |
  |----|------|
  | 同名判定 | 按 `groupId:artifactId` 判同名，**不看版本**，也不看打包/classifier |
  | 同名取值 | 取 `[libs]` 里那一条，**版本用 `[libs]` 的**；内置清单里的同名项整条丢弃 |
  | classpath 顺序 | `[libs]` 在前、内置在后（因此被保留的 libs 版本优先命中，且不会出现两个版本并存） |
  | 用途 | 补依赖（写新的 `g:a`）与换版本（写同名 `g:a` 的不同版本）都是这一条规则 |

  该规则在 jstart 侧（应用 classpath）与容器侧（`DependencyClassLoader` 合并 war 清单）
  一致，也与 bas `Webapp libs` 的 merge 一致；`[subapp <id>] libs` 同样遵循。
- 不写 `[libs]` 时只用 entry 内的依赖描述（jar/war/解压目录各位置规则与现有
  `resolveDependencies` 完全一致）；native（tar.gz）包内没有清单，`[libs]` 即为全部依赖；
- `[app] main` 与 entry 内 Manifest `Main-Class` 都缺失时，`run` 报
  `Cannot find Main-Class` 并退出 1（声明了引擎的 war/目录例外：不需要 main，直接进入
  引擎运行流程，见 [war-engine.md](war-engine.md)）；
- **`[app] main` 与 `[engine]` 段互斥**：jar 由 java 直接跑主类，引擎目标由 init 命令
  启动，两者语义冲突；同时声明时 `run`/`resolve` 等命令直接报错退出 1
  （命令行 `--main` 与 engine 目标并存仍按"war 忽略 --main"告警，见下）；
- 未知段/未知键：告警并忽略（向前兼容）；重复键取最后值，列表行按出现顺序追加；
- `[args]`/`[runtime]` 不做 shell 语义：值与注释由文件行界定，杜绝引号转义问题。
- **参数一律不做解析**：`[args]` 每行原样作为一个 argv；`run` 命令行上无法识别的参数
  （如 `--port=8080`、`--k v`、`-k=v`）同样原样透传，jstart 不解释键值结构——写法众口
  难调（`-k=v` 与 `--k v` 并存），统一交给应用自行处理；`-D`/`-X` 开头归运行时
  （java 即 JVM 参数，与非 spec 的 jar 目标一致）。
- **主类可覆盖**：Java 主类按 `--main=<class>` > `[app] main` >
  entry 内 `MANIFEST.MF` 的 `Main-Class` 确定，命令行覆盖适合临时试参数、文件里的
  `[app] main` 适合固化（见 [commands.md](commands.md)）；
- **其余运行时定制只在 spec 内**：运行时参数用 `[runtime]` 段、运行时/解释器可执行文件用
  `[app] runtime`；不提供 `--jvm=`/`--runtime=` 之类的命令行覆盖，避免同一参数在文件与
  命令行两处出现（试参数请直接改文件或加 `[args]` 行）。
- **引擎定制也只在 spec 内**：`[engine] init` 选 init 命令、`[engine]` 其余行罗列引擎
  依赖，详见下文"war 目标与引擎定制"。

### 启动模型（LaunchType，由解析结果派生）

jstart 在解析 spec 后给每个目标派生一个**启动模型**（`LaunchType`，取值 `app`/`engine`）。
它**不是 spec 键**——不需要、也不允许在文件里写 `type = engine`——而是 jstart 从"是否声明
了引擎"得出的结论，供内部与 `info` 输出统一判断分支：

| 模型 | 含义 | 判定 |
|------|------|------|
| `app` | 直接 exec 运行时：java 跑 jar/解压目录，或 native（tar.gz）可执行文件 | 默认 |
| `engine` | 先跑**引擎 init 命令**准备容器环境，再 exec 它写出的命令 | 声明了 `[engine]` 段，或有 `[subapp <id>]` 多 webapp |

- **只看声明，不靠推断**：jstart 不内置引擎目录，也不从 entry 的 `.war` 后缀反推。
  war 想跑就必须显式写 `[engine] init`；没写引擎声明的 spec 是 `app`，
  `run` 会对 war 报错提示补声明。
- `info` 输出的 `type:` 就是这个模型（`app`/`engine`）；entry 自身的**构件形态**另用
  `entry type:`（`jar`/`war`/`dir`/`native`/`file`）报告，两者不要混淆。

### war 目标与引擎定制（[engine] init / [engine] 依赖）

war 没有 `Main-Class`，且 `run` 只接受 launch spec 形式的 war 目标（`[app] entry` 为
war 文件/gav；裸 war 目标会报错并提示写 spec；`resolve`/`fetch`/`repo` 仍直接接受
war）。此时 jstart 先运行 spec 声明的**引擎 init 命令**（准备容器环境，写出最终启动
命令）再 exec 它，两端协议见 [engine.md](engine.md)、war 侧用法见
[war-engine.md](war-engine.md)。引擎的"用哪个入口、带哪些 jar"由 spec 定制：

```ini
[app]
entry = /path/app.war          # war 目标（本地文件/gav/http 均可）

[engine]                       # init 必填；其余行是引擎启动器依赖，同 [libs] 语法
init = /opt/engine/bin/tomcat-init   # 引擎 init 命令（路径，或“程序 + 参数”；不是 java 类）
org.beangle.bas:beangle-bas-engine:0.13.17
org.apache.tomcat.embed:tomcat-embed-core:11.0.21
org.apache.tomcat.embed:tomcat-embed-websocket:11.0.21

[runtime]                      # 引擎 JVM 参数（jar/war 通用）
-Xmx1g

[args]                         # 引擎运行参数，原样交给 init 命令转发
--port=8080
--path=/
```

定制规则：

- **声明 init 命令**：`init` 是**命令行**（程序 + 参数），最简是单个可执行文件/脚本路径
  （`~`/`${VAR}` 会展开）；程序自己决定调用哪个容器入口类。jstart 不做别名/FQCN 映射，
  也没有内置引擎。
- **罗列引擎依赖**：`init` 之外的行是引擎 jar 清单，jstart 不内置任何依赖行——锁版本、
  升级、换镜像、引用本地引擎 jar、切容器都只改本文件，容器 jar 也要写全（没有内置目录
  可回退，见 [war-engine.md](war-engine.md)）。每行原样解析，**没有占位符**，版本号直接写；
  依赖可以留空（init 命令自带 classpath 时如此）。
- **声明了 `[engine]` 就是引擎目标**：war/目录都要写；jar/native 目标写了 `[engine]`
  也会被判为 `engine` 类型走引擎流程，通常没有意义，应去掉。
- **与应用依赖互不影响**：`[libs]`（或 war 内置清单）负责应用本体，`[engine]` 只负责
  引擎启动器；classpath 顺序为"应用 classes/lib + 应用依赖 → 引擎依赖"，引擎 gav 与
  应用依赖按 `g:a:v` 去重。
- **运行参数**：引擎 JVM 参数写 `[runtime]`（`-D`/`-X` 开头参数同理，jstart 作为
  `--app-jvm-arg` 交给 init 命令写进最终命令）；`--port=8080`、`--path=/` 等引擎运行参数
  写 `[args]`（或命令行透传），jstart 全部原样交给 init 命令，不吞参数。
- **不做 CLI 定制**：没有 `--engine=` 之类的命令行覆盖，`[engine]` 段也不解析
  `main=...` 之类的键值行——`init` 之外的每行就是一条依赖（与 `[libs]` 完全同构）。
- 引擎 jar 同样遵守"不解析传递依赖"约束：`[engine]` 里必须显式写全。

### 多 webapp（[subapp \<id\>]）

同一个引擎跑多个 war 时，用若干个 `[subapp <id>]` 段声明，**一个 spec 文件**即可，
每个 webapp 一个独立上下文路径：

```ini
[engine]
init = /opt/engine/bin/tomcat-server-init                # 必填：引擎 init 命令（路径，或“程序 + 参数”）
org.beangle.bas:beangle-bas-engine:0.13.17
org.apache.tomcat:tomcat:11.0.21:zip                   # 多 context 用全量 tomcat 发行包

[subapp portal]
entry = /srv/deploy/portal.war
path = /portal
libs = com.zaxxer:HikariCP:7.0.3-SNAPSHOT

[subapp admin]
entry = /srv/deploy/admin.war
path = /admin
```

约定与规则：

- **必须声明 `[engine] init`**：多应用在校验阶段就要求 `[engine]` 段存在且给了 `init`
  命令（没有缺省引擎/内置目录）；缺一即报错。一个 JVM 跑多个 webapp 是 init 命令的职责，
  通常由 basctl 的 `make tomcat-server` 之类多 context 入口承担。
- **每个 webapp 必须有 `entry` 和 `path`**，归一化后（去尾 `/`、补首个 `/`、折叠
  `//`）的 context path 不能重复（`/` 只允许一个）；段头 id 不能重复、不能含空格/制表符。
- **`libs` 是该 webapp 的扩展依赖**（gav 坐标，可多行、一行可逗号分隔多个）：覆盖规则与
  顶层 `[libs]` 完全相同——按 `groupId:artifactId` 判同名（不看版本），同名取 libs 的
  版本，追加/覆盖在该 war 的 `META-INF/beangle/dependencies` 清单之上，由引擎的
  `DependencyClassLoader` 合并（对齐 bas 的 `Webapp libs`）。jstart 会先把它们取回本地
  仓库——引擎只在本地仓库里找、缺失即报错；被覆盖的旧版本不再需要下载。`[subapp] libs`
  只认 gav（引擎侧只支持 gav），顶层 `[libs]` 另支持本地文件/远程 url。
- **与单应用的键互斥**：`[app] entry`、`[app] main`、`[libs]` 都不能和 `[subapp]` 段
  共存——多应用每个 war 各用自身的 `META-INF/beangle/dependencies` 清单，顶层 `[libs]`
  无法用一份清单表达多个应用。
- **各 webapp 依赖相互隔离**：jstart 逐个取回 webapp 并把各自依赖补齐到本地仓库；运行时
  由容器内每个 Context 自己的 `DependencyClassLoader` 按各自 war 清单解析（jstart 透传
  `--local-repo`），**不**把多个应用的依赖合并进同一个 JVM classpath——那样会串味。
- **共享生命周期**：一个 spec 一个 base（`--base`/`[app] base`/`[app] instance`），一份 pid
  文件，`stop` 一次停整组；`resolve`/`info` 按 webapp 逐个输出，`classpath` 对多应用
  无意义会明确拒绝。
- **接口形式**：入口、context path 与 `libs` 写进 `<base>/engine-subapps.jstart`
  （launch spec 片段，一段一个 `[subapp <id>]`），init 命令按 `--base` 从该约定路径读取，
  不经命令行传递（单应用仍走 `--entry=`/`--path=`/`--app-classpath-file=`）；协议见
  [engine.md](engine.md)。

## 与现有命令的关系

spec 文件可作为 `run`/`resolve`/`classpath`/`repo` 的 target：

```bash
jstart run app.jstart                    # 解析 spec → 准备依赖 → exec java
jstart resolve app.jstart                # 解析并下载依赖，输出 entry 落盘绝对路径
jstart classpath app.jstart              # 输出 Main-Class@classpath（main 取 spec 或 Manifest）
jstart repo app.jstart --local=/opt/offline-repo   # 离线整合（取 [libs] 或内置清单）
jstart run https://repo.example.com/app.jstart     # 远程 spec：下载后按 entry 解析
```

`repo` 是离线整合命令，只接受**本地** `.jstart`（spec 的 `entry` 也必须是本地
文件/目录），不下载远程 spec。

内部实现上，spec 被解析为"entry + 依赖清单 + 启动参数"的合成目标，之后的依赖准备、
classpath 装配、exec 流程与现有 jar 目标共用同一套代码。`run` 的可启动目标就是
launch spec（或带应用本体的 jar/gav/url）；**普通文本文件不再支持为依赖清单
target**（任何命令都不接受），依赖清单只来自 jar/war 内置描述或 spec 的 `[libs]`。

## --print：只打印将要执行的命令

`jstart run --print app.jstart`（对 jar 目标同样可用）：

- 照常解析、下载并装配 classpath（与 `run` 的准备工作一致）；
- 不 exec，而是把将要执行的命令行打印到 stdout，每个参数按 POSIX 单引号规则转义，
  可直接复制执行；
- 用于审计、脚本包装与 CI 调试；对 deps 不齐等准备失败，退出码与 `run` 一致。

```bash
$ jstart run --print app.jstart
java -Xmx512m -XX:+UseG1GC -Dfile.encoding=UTF-8 -cp 'app.jar:...' org.beangle.app.Main '--port=8080' '--path=/base'
```

## 范围与规划

- **v0.1.0 候选范围**：launch spec 文件解析（含 `[libs]` 追加/覆盖语义）+ `run`/其余
  命令支持 spec target + `run --print`。
- `info` 命令已实现：解析并准备依赖后输出 main、依赖数、各依赖来源与本地落盘、体积等
  结构化信息（文本 `key: value`，依赖逐行 `dep <n>: ...`），服务审计与 IDE/CI 集成，
  详见 [commands.md](commands.md)。
- **不规划** `prefetch` 预下载命令：它等于 `resolve` + 循环清单，价值有限；除非以后有
  "独立指定一组依赖清单批量预热"的明确场景再单独立项。
- **war 引擎运行已实现**：war 由 launch spec 的 `[app] entry` 声明后，`run` 运行引擎
  init 命令准备环境、再 exec 容器（launch spec 用 `[engine] init` 选 init 命令、
  `[engine]` 其余行罗列引擎 + 容器 jar——jstart 不内置依赖目录，必须显式声明），见
  [engine.md](engine.md) 与 [war-engine.md](war-engine.md)。
- 下载侧已排入路线图（跨版本，与 spec 无关）：Range 多线程分段下载与断点续传、
  SNAPSHOT 时间戳版本解析（`~/.m2/snapshots`）；另有 zip/war/ear `.diff` 增量补丁与
  Windows 原生支持等既有路线图项，见 [release-v0.0.1.md](release-v0.0.1.md)。

## 边界决策

1. **主类可命令行覆盖，其余定制只在 spec 内**：主类按 `--main=` > `[app] main` >
   entry 内 `MANIFEST.MF` 的 `Main-Class` 确定——临时试参数用命令行，
   固化用 spec。运行时/引擎定制仍在 spec 内声明（`[app] runtime` 与
   `[runtime]`/`[engine]` 段），不提供 `--jvm=`/`--engine=` 之类的命令行参数；旧命名
   `[jvm]` 段与 `[app] java` 键已移除（视为未知段/未知键告警）。
2. **`[args]` 不做简写/解析**：不支持 `key = value → --key=value` 之类的转换；`-k=v`、
   `--k v`、位置参数等一律原样透传，由应用自行解释。
3. **行号告警已实现**：未知段/未知键/格式错误会在 stderr 输出 `line N: ...` 告警并被忽略。
