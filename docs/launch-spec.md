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
  本文件的 `[deps]` 段）。

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

[runtime]
-Xmx512m                               # 每行一个运行时参数，原样拼接（不做 shell 切分）
-XX:+UseG1GC
-Dfile.encoding=UTF-8

[args]
--port=8080                            # 每行一个应用参数，原样作为单个 argv（不做 shell 切分）
--path=/base

[deps]
com.zaxxer:HikariCP:7.0.2              # 可选段：每行与依赖描述文件完全同语法
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

[deps]                                 # 可选：native 包内没有依赖清单，需要时在此显式罗列
```

### 段与键

| 段 | 键/内容 | 说明 |
|----|---------|------|
| `[app]` | `base` | 可选。base 根目录，替换缺省的 `/var/tmp/jstart`；组件的运行目录是 `<base>/<组件键>`（pid 文件、native 解压、war 解压都在其下），`run`/`stop` 用同一个 base 找实例（见 [commands.md](commands.md)） |
| `[app]` | `main` | 可选（Java）。主类全名，命令行 `--main=<class>` 优先于本键。缺省时回退：entry 为 jar 时读其 Manifest `Main-Class`；仍无则 run 报错（war/native 目标不需要主类，见下）。**与 `[app] engine`/`[engine]` 互斥**，同时出现直接报错 |
| | `entry` | 必填。取值同现有 target：`g:a:v`/`gav://`、native 的 `g:a:tar.gz:<classifier>:v`、`http(s)://`、本地 jar/war/tar.gz/解压目录/文件路径 |
| | `working_dir` | 可选。exec 前切换工作目录，沿用 `~`/`${VAR}` 展开 |
| | `runtime` | 可选。运行时/解释器可执行文件（`java`/`python3`/`node`/...）或 java 安装目录（自动补 `bin/java`）；支持 `~`/`${VAR}` 展开；缺省按 entry 推断（jar → `$JAVA_HOME`/PATH 的 java） |
| | `exec` | 可选（native tar.gz）。包内可执行文件，**相对解压根目录**（如 `demo-1.0/bin/demo`）；缺省自动探测 `<name>/bin/<exe>` 或唯一可执行文件；jar/war entry 忽略此键 |
| | `engine` | 可选（仅 war/目录）。入口 main：含 `.` 的值当 FQCN，否则内置别名 `tomcat`/`undertow`（war 缺省 `tomcat`，映射 `org.beangle.sas.engine.<name>.EmbedCreator`）；tomcat 别名可带版本后缀 `tomcat-11.0.24`（无后缀用内置默认版本）；FQCN 一般无内置目录、须写 `[engine]`（例外：ServerCreator 有内置目录）；jar/native 目标写了则告警忽略（见 [engine.md](engine.md)）。**与 `[app] main` 互斥** |
| `[runtime]` | 行列表 | 每个非注释行是一个运行时参数（Java 的 `-D`/`-X`/`--add-opens`、Python 的 `-O` 等），按书写顺序拼接；native（tar.gz）目标无 JVM，该段告警忽略 |
| `[args]` | 行列表 | 每个非注释行是一个应用参数，**整行**作为一个 argv：不切分、不展开变量，值含空格可直接书写；native 目标同样附加在可执行文件之后 |
| `[deps]` | 行列表 | 可选。每行语法与依赖描述文件一致（gav/本地文件/远程 url） |
| `[engine]` | 行列表 | 可选（仅 war/目录）。引擎启动器依赖逐行罗列，语法同 `[deps]`（gav/本地文件/远程 url），行内可用占位符 `{tomcat.version}`/`{sas.version}` 引用内置版本；**段存在即为权威**（不依赖内置行），否则回退内置默认目录（tomcat/undertow，见 [engine.md](engine.md)） |
| `[subapp <id>]` | `entry` / `path` | 可选、可重复。**多应用**：一个 dist 引擎在同一 JVM 里跑多个 webapp，每个一段；`entry` 同 `[app] entry`，`path` 是该 webapp 的上下文路径（归一化后各自唯一）。与 `[app] entry`/`main`/`[deps]` 互斥，引擎只能走 Dist（见下） |

### 语义约定

- `[deps]` **存在**时它是依赖的唯一来源，不再读取 entry 内置的
  `META-INF/beangle/dependencies`（本地开发覆盖内置清单的手段，也保持"显式依赖"约束）；
- `[deps]` **不存在**时自动回退读取 entry 内的依赖描述（jar/war/解压目录各位置规则
  与现有 `resolveDependencies` 完全一致）；
- `[app] main` 与 entry 内 Manifest `Main-Class` 都缺失时，`run` 报
  `Cannot find Main-Class` 并退出 1（war 目标例外：不需要 main，直接进入内置引擎
  运行流程，见 [war-engine.md](war-engine.md)）；
- **`[app] main` 与 `[app] engine` / `[engine]` 互斥**：jar 由 java 直接跑主类，war 的
  入口是引擎的 entry main，两者语义冲突；同时声明时 `run`/`resolve` 等命令直接报错退出 1
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
- **引擎定制也只在 spec 内**：`[app] engine` 选择、`[engine]` 段罗列引擎依赖，二者
  仅对 war 目标生效，详见下文"war 目标与引擎定制"。

### war 目标与引擎定制（[app] engine / [engine]）

war 没有 `Main-Class`，且 `run` 只接受 launch spec 形式的 war 目标（`[app] entry` 为
war 文件/gav；裸 war 目标会报错并提示写 spec；`resolve`/`fetch`/`repo` 仍直接接受
war）。此时 jstart 先运行**引擎入口 main**（准备容器环境，写出最终启动命令）再 exec
它，两端协议见 [engine.md](engine.md)、war 侧用法见 [war-engine.md](war-engine.md)。
引擎的"选哪个、带哪些 jar"由 spec 定制：

```ini
[app]
entry = /path/app.war          # war 目标（本地文件/gav/http 均可）
engine = tomcat                # 可选：tomcat | undertow；war 缺省 tomcat
                               # tomcat 可带版本：tomcat-11.0.24

[engine]                       # 可选：引擎启动器依赖，每行与 [deps] 同语法
org.beangle.sas:beangle-sas-engine:0.13.17
org.apache.tomcat.embed:tomcat-embed-core:11.0.21
org.apache.tomcat.embed:tomcat-embed-websocket:11.0.21
                               # 行内可用占位符：{tomcat.version}/{sas.version}

[runtime]                      # 引擎 JVM 参数（jar/war 通用）
-Xmx1g

[args]                         # 引擎运行参数，原样交给入口 main 转发
--port=8080
--path=/
```

定制规则：

- **选择引擎**：`[app] engine` 含 `.` 的值当入口 main 的 FQCN；否则是内置别名
  `tomcat`/`undertow`（映射 `org.beangle.sas.engine.<name>.EmbedCreator`），war 缺省
  `tomcat`，未知别名在 `run` 时报错；FQCN 一般没有内置目录、必须写 `[engine]`（例外：
  全量 tomcat 的 `ServerCreator` 有内置目录）。tomcat 别名
  可带版本后缀 `tomcat-11.0.24`：不写 `[engine]` 段时内置目录的 `tomcat-embed-*`
  自动用该版本（`beangle-sas-engine` 仍用内置默认版本）。entry 是 war/目录时都走引擎，
  其它目标（jar/native）**不要求** engine 声明，写了会告警并忽略。
- **罗列引擎依赖**：`[engine]` 段存在即为权威，jstart 不内置依赖行——锁版本、升级、
  换镜像、引用本地引擎 jar 都只改本文件；没有 `[engine]` 段时回退**内置默认目录**
  （tomcat 3 个 / undertow 22 个 jar，等价 sas.sh 两个分支的 download 行，版本随
  jstart 固定）。行内可用占位符：`{tomcat.version}` 取 `engine = tomcat-<版本>` 的
  版本、否则内置默认，`{sas.version}` 取内置默认——例如
  `org.apache.tomcat.embed:tomcat-embed-core:{tomcat.version}`。只换 tomcat 版本可写
  `engine = tomcat-<版本>`；覆盖其它（undertow、镜像、sas 引擎等）就写 `[engine]`
  段，都不必等 jstart 发版。
- **与应用依赖互不影响**：`[deps]`（或 war 内置清单）负责应用本体，`[engine]` 只负责
  引擎启动器；classpath 顺序为"应用 classes/lib + 应用依赖 → 引擎依赖"，引擎 gav 与
  应用依赖按 `g:a:v` 去重。
- **运行参数**：引擎 JVM 参数写 `[runtime]`（`-D`/`-X` 开头参数同理，jstart 作为
  `--app-jvm-arg` 交给入口 main 写进最终命令）；`--port=8080`、`--path=/` 等引擎运行参数
  写 `[args]`（或命令行透传），jstart 全部原样交给入口 main，不吞参数。
- **不做定制**：引擎主类由引擎名固定，没有 CLI 覆盖（无 `--engine=`），`[engine]` 段
  也不解析 `main=...` 之类的键值行——每行就是一条依赖（与 `[deps]` 完全同构）。
- 引擎 jar 同样遵守"不解析传递依赖"约束：目录/`[engine]` 里必须显式写全。

### 多 webapp（[subapp \<id\>]）

同一个引擎跑多个 war 时，用若干个 `[subapp <id>]` 段声明，**一个 spec 文件**即可，
每个 webapp 一个独立上下文路径：

```ini
[app]
engine = org.beangle.sas.engine.tomcat.ServerCreator   # 可省略，多应用缺省即 ServerCreator

[subapp portal]
entry = /srv/deploy/portal.war
path = /portal

[subapp admin]
entry = /srv/deploy/admin.war
path = /admin
```

约定与规则：

- **多应用只走 Dist 模式**：内嵌引擎（`tomcat`/`undertow` 别名、`*EmbedCreator`）只跑
  一个 webapp，写成 `[app] engine = tomcat` 之类会在 spec 校验阶段直接报错。`[app]
  engine` 省略时用内置的 Dist 引擎入口 main `org.beangle.sas.engine.tomcat.ServerCreator`。
- **每个 webapp 必须有 `entry` 和 `path`**，归一化后（去尾 `/`、补首个 `/`、折叠
  `//`）的 context path 不能重复（`/` 只允许一个）；段头 id 不能重复、不能含空格/制表符。
- **与单应用的键互斥**：`[app] entry`、`[app] main`、`[deps]` 都不能和 `[subapp]` 段
  共存——多应用每个 war 各用自身的 `META-INF/beangle/dependencies` 清单，`[deps]` 无法
  用一份清单表达多个应用。
- **各 webapp 依赖相互隔离**：jstart 逐个取回 webapp 并把各自依赖补齐到本地仓库；运行时
  由容器内每个 Context 自己的 `DependencyClassLoader` 按各自 war 清单解析（jstart 透传
  `--Dsas.repo`），**不**把多个应用的依赖合并进同一个 JVM classpath——那样会串味。
- **共享生命周期**：一个 spec 一个 base（`--base`/`--instance`/`[app] base`），一份 pid
  文件，`stop` 一次停整组；`resolve`/`info` 按 webapp 逐个输出，`classpath` 对多应用
  无意义会明确拒绝。
- **接口形式**：入口与 context path 写进 `<base>/engine-webapps.tsv`（每行
  `id \t entry \t path`），用 `--webapps-file=` 交给 Dist 引擎（单应用仍走
  `--entry=`/`--path=`/`--app-classpath-file=`）；协议见 [engine.md](engine.md)。

## 与现有命令的关系

spec 文件可作为 `run`/`resolve`/`classpath`/`repo` 的 target：

```bash
jstart run app.jstart                    # 解析 spec → 准备依赖 → exec java
jstart resolve app.jstart                # 解析并下载依赖，输出 entry 落盘绝对路径
jstart classpath app.jstart              # 输出 Main-Class@classpath（main 取 spec 或 Manifest）
jstart repo app.jstart --local=/opt/offline-repo   # 离线整合（取 [deps] 或内置清单）
jstart run https://repo.example.com/app.jstart     # 远程 spec：下载后按 entry 解析
```

`repo` 是离线整合命令，只接受**本地** `.jstart`（spec 的 `entry` 也必须是本地
文件/目录），不下载远程 spec。

内部实现上，spec 被解析为"entry + 依赖清单 + 启动参数"的合成目标，之后的依赖准备、
classpath 装配、exec 流程与现有 jar 目标共用同一套代码。`run` 的可启动目标就是
launch spec（或带应用本体的 jar/gav/url）；**普通文本文件不再支持为依赖清单
target**（任何命令都不接受），依赖清单只来自 jar/war 内置描述或 spec 的 `[deps]`。

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

- **v0.1.0 候选范围**：launch spec 文件解析（含 `[deps]` 回退/覆盖语义）+ `run`/其余
  命令支持 spec target + `run --print`。
- `info` 命令已实现：解析并准备依赖后输出 main、依赖数、各依赖来源与本地落盘、体积等
  结构化信息（文本 `key: value`，依赖逐行 `dep <n>: ...`），服务审计与 IDE/CI 集成，
  详见 [commands.md](commands.md)。
- **不规划** `prefetch` 预下载命令：它等于 `resolve` + 循环清单，价值有限；除非以后有
  "独立指定一组依赖清单批量预热"的明确场景再单独立项。
- **war 引擎运行已实现**：war 由 launch spec 的 `[app] entry` 声明后，`run` 运行引擎
  入口 main 准备环境、再 exec 内嵌容器（tomcat/undertow；launch spec 用 `[app] engine`
  选入口 main、`[engine]` 段罗列引擎依赖，两个引擎都有内置默认目录兜底），见
  [engine.md](engine.md) 与 [war-engine.md](war-engine.md)。
- 下载侧已排入路线图（跨版本，与 spec 无关）：Range 多线程分段下载与断点续传、
  SNAPSHOT 时间戳版本解析（`~/.m2/snapshots`）；另有 zip/war/ear `.diff` 增量补丁与
  Windows 原生支持等既有路线图项，见 [release-v0.0.1.md](release-v0.0.1.md)。

## 边界决策

1. **主类可命令行覆盖，其余定制只在 spec 内**：主类按 `--main=` > `[app] main` >
   entry 内 `MANIFEST.MF` 的 `Main-Class` 确定——临时试参数用命令行，
   固化用 spec。运行时/引擎定制仍在 spec 内声明（`[app] runtime`、`[app] engine` 与
   `[runtime]`/`[engine]` 段），不提供 `--jvm=`/`--engine=` 之类的命令行参数；旧命名
   `[jvm]` 段与 `[app] java` 键已移除（视为未知段/未知键告警）。
2. **`[args]` 不做简写/解析**：不支持 `key = value → --key=value` 之类的转换；`-k=v`、
   `--k v`、位置参数等一律原样透传，由应用自行解释。
3. **行号告警已实现**：未知段/未知键/格式错误会在 stderr 输出 `line N: ...` 告警并被忽略。
