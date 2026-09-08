# Launch Spec：启动说明文件

`run` 的另一种输入形态：一个类似 ini 的文本文件，声明"启动一个应用"所需的一切——
Java 主类（main）、应用本体来源（entry）、运行时/解释器（runtime）及其参数、
应用参数与依赖清单。它解决现有两个场景缺口：

- 只有依赖无法启动：依赖清单要么随应用本体内置（jar/war），要么由 launch spec
  携带；spec 在清单基础上把 main/entry 显式声明出来；
- 应用"怎么启动"（含 `--port=8080` 这类参数、运行时参数）从散落的命令行/脚本收敛为
  一份可提交、可评审、可复用的文件——`run` 的声明式目标就是 launch spec。

> runtime 取 java 之外的值（如 `python3`、`node`）是为后续接入原生/解释型目标预留：
> 当前 `run` 仍只 exec java（jar 目标），但 spec 结构已不再绑定 Java 术语。

## 文件识别

- 扩展名为 `.launch`（建议；别名 `.jstart`）的文件直接按 launch spec 解析；
- 其余文本文件若首个非空、非注释行以 `[` 段头开头，也按 launch spec 解析；
- 都不是则不是 launch spec：普通文本文件**不再支持**为依赖清单 target
  （依赖清单只来自 jar/war 内置描述或本文件的 `[deps]` 段）。

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

### 段与键

| 段 | 键/内容 | 说明 |
|----|---------|------|
| `[app]` | `main` | 可选（Java）。主类全名。缺省时回退：entry 为 jar 时读其 Manifest `Main-Class`；仍无则 run 报错 |
| | `entry` | 必填。取值同现有 target：`g:a:v`/`gav://`、`http(s)://`、本地 jar/war/解压目录/文件路径 |
| | `working_dir` | 可选。exec 前切换工作目录，沿用 `~`/`${VAR}` 展开 |
| | `runtime` | 可选。运行时/解释器可执行文件（`java`/`python3`/`node`/...）或 java 安装目录（自动补 `bin/java`）；支持 `~`/`${VAR}` 展开；缺省按 entry 推断（jar → `$JAVA_HOME`/PATH 的 java） |
| | `engine` | 可选（仅 war）。内嵌引擎名 `tomcat`/`undertow`（war 缺省 `tomcat`）；tomcat 可带版本后缀 `tomcat-11.0.24`（无后缀用内置默认版本）；jar/其它运行时不需要、写了则告警忽略（见 [war-engine.md](war-engine.md)） |
| `[runtime]` | 行列表 | 每个非注释行是一个运行时参数（Java 的 `-D`/`-X`/`--add-opens`、Python 的 `-O` 等），按书写顺序拼接 |
| `[args]` | 行列表 | 每个非注释行是一个应用参数，**整行**作为一个 argv：不切分、不展开变量，值含空格可直接书写 |
| `[deps]` | 行列表 | 可选。每行语法与依赖描述文件一致（gav/本地文件/远程 url） |
| `[engine]` | 行列表 | 可选（仅 war）。引擎启动器依赖逐行罗列，语法同 `[deps]`（gav/本地文件/远程 url），行内可用占位符 `{tomcat.version}`/`{sas.version}` 引用内置版本；**段存在即为权威**（不依赖内置行），否则回退内置默认目录（tomcat/undertow，见 [war-engine.md](war-engine.md)） |

### 语义约定

- `[deps]` **存在**时它是依赖的唯一来源，不再读取 entry 内置的
  `META-INF/beangle/dependencies`（本地开发覆盖内置清单的手段，也保持"显式依赖"约束）；
- `[deps]` **不存在**时自动回退读取 entry 内的依赖描述（jar/war/解压目录各位置规则
  与现有 `resolveDependencies` 完全一致）；
- `[app] main` 与 entry 内 Manifest `Main-Class` 都缺失时，`run` 报
  `Cannot find Main-Class` 并退出 1（war 目标例外：不需要 main，直接进入内置引擎
  运行流程，见 [war-engine.md](war-engine.md)）；
- 未知段/未知键：告警并忽略（向前兼容）；重复键取最后值，列表行按出现顺序追加；
- `[args]`/`[runtime]` 不做 shell 语义：值与注释由文件行界定，杜绝引号转义问题。
- **参数一律不做解析**：`[args]` 每行原样作为一个 argv；`run` 命令行上无法识别的参数
  （如 `--port=8080`、`--k v`、`-k=v`）同样原样透传，jstart 不解释键值结构——写法众口
  难调（`-k=v` 与 `--k v` 并存），统一交给应用自行处理；`-D`/`-X` 开头归运行时
  （java 即 JVM 参数，与非 spec 的 jar 目标一致）。
- **运行时定制只在 spec 内**：Java 主类用 `[app] main`、运行时参数用 `[runtime]` 段、
  运行时/解释器可执行文件用 `[app] runtime`；不提供 `--main-class=`/`--jvm=` 之类的
  命令行覆盖，避免同一参数在文件与命令行两处出现（试参数请直接改文件或加 `[args]` 行）。
- **引擎定制也只在 spec 内**：`[app] engine` 选择、`[engine]` 段罗列引擎依赖，二者
  仅对 war 目标生效，详见下文"war 目标与引擎定制"。

### war 目标与引擎定制（[app] engine / [engine]）

war 没有 `Main-Class`，`run` 对 war 目标（或 entry 为 war 的 spec）自动进入内置引擎
流程：爆炸到 `<base>/webapps/<ctx>` 后 exec `org.beangle.sas.engine.<name>.Bootstrap`，
完整语义见 [war-engine.md](war-engine.md)。引擎的"选哪个、带哪些 jar"由 spec 定制：

```ini
[app]
entry = /path/app.war          # war 目标（本地文件/gav/http 均可）
engine = tomcat                # 可选：tomcat | undertow；war 缺省 tomcat
                               # tomcat 可带版本：tomcat-11.0.24

[engine]                       # 可选：引擎启动器依赖，每行与 [deps] 同语法
org.beangle.sas:beangle-sas-engine:0.13.10
org.apache.tomcat.embed:tomcat-embed-core:11.0.21
org.apache.tomcat.embed:tomcat-embed-websocket:11.0.21
                               # 行内可用占位符：{tomcat.version}/{sas.version}

[runtime]                      # 引擎 JVM 参数（jar/war 通用）
-Xmx1g

[args]                         # 引擎运行参数，原样传给 Bootstrap
--port=8080
--path=/
```

定制规则：

- **选择引擎**：`[app] engine` 只接受内置名 `tomcat`/`undertow`（主类分别映射
  `org.beangle.sas.engine.tomcat.Bootstrap` 与 `org.beangle.sas.engine.undertow.Bootstrap`）；
  war 缺省 `tomcat`；未知名在 `run` 时报错。tomcat 可带版本后缀 `tomcat-11.0.24`：
  不写 `[engine]` 段时内置目录的 `tomcat-embed-*` 自动用该版本（`beangle-sas-engine`
  仍用内置默认版本）。jar / 非 java 运行时目标**不要求** engine 声明，写了会告警并忽略。
- **罗列引擎依赖**：`[engine]` 段存在即为权威，jstart 不内置依赖行——锁版本、升级、
  换镜像、引用本地引擎 jar 都只改本文件；没有 `[engine]` 段时回退**内置默认目录**
  （tomcat 3 个 / undertow 14 个 jar，等价 sas.sh 两个分支的 download 行，版本随
  jstart 固定）。行内可用占位符：`{tomcat.version}` 取 `engine = tomcat-<版本>` 的
  版本、否则内置默认，`{sas.version}` 取内置默认——例如
  `org.apache.tomcat.embed:tomcat-embed-core:{tomcat.version}`。只换 tomcat 版本可写
  `engine = tomcat-<版本>`；覆盖其它（undertow、镜像、sas 引擎等）就写 `[engine]`
  段，都不必等 jstart 发版。
- **与应用依赖互不影响**：`[deps]`（或 war 内置清单）负责应用本体，`[engine]` 只负责
  引擎启动器；classpath 顺序为"应用 classes/lib + 应用依赖 → 引擎依赖"，引擎 gav 与
  应用依赖按 `g:a:v` 去重。
- **运行参数**：引擎 JVM 参数写 `[runtime]`；`--port=8080`、`--path=/` 等引擎运行参数
  写 `[args]`（或命令行透传）。引擎模式只**读取** `--path=`/`--base=` 用于爆炸布局，
  之后仍原样转发给引擎，不吞参数。
- **不做定制**：引擎主类由引擎名固定，没有 CLI 覆盖（无 `--engine=`），`[engine]` 段
  也不解析 `main=...` 之类的键值行——每行就是一条依赖（与 `[deps]` 完全同构）。
- 引擎 jar 同样遵守"不解析传递依赖"约束：目录/`[engine]` 里必须显式写全。

## 与现有命令的关系

spec 文件可作为 `run`/`resolve`/`classpath`/`repo` 的 target：

```bash
jstart run app.launch                    # 解析 spec → 准备依赖 → exec java
jstart resolve app.launch                # 解析并下载依赖，输出 entry 落盘绝对路径
jstart classpath app.launch              # 输出 Main-Class@classpath（main 取 spec 或 Manifest）
jstart repo app.launch --local=/opt/offline-repo   # 离线整合（取 [deps] 或内置清单）
```

内部实现上，spec 被解析为"entry + 依赖清单 + 启动参数"的合成目标，之后的依赖准备、
classpath 装配、exec 流程与现有 jar 目标共用同一套代码。`run` 的可启动目标就是
launch spec（或带应用本体的 jar/gav/url）；**普通文本文件不再支持为依赖清单
target**（任何命令都不接受），依赖清单只来自 jar/war 内置描述或 spec 的 `[deps]`。

## --print：只打印将要执行的命令

`jstart run --print app.launch`（对 jar 目标同样可用）：

- 照常解析、下载并装配 classpath（与 `run` 的准备工作一致）；
- 不 exec，而是把将要执行的命令行打印到 stdout，每个参数按 POSIX 单引号规则转义，
  可直接复制执行；
- 用于审计、脚本包装与 CI 调试；对 deps 不齐等准备失败，退出码与 `run` 一致。

```bash
$ jstart run --print app.launch
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
- **war 引擎运行已实现**：`run` 对 war 目标爆炸后 exec 内嵌引擎（tomcat/undertow；
  launch spec 用 `[app] engine` 选择、`[engine]` 段罗列引擎依赖，两个引擎都有内置
  默认目录兜底），见 [war-engine.md](war-engine.md)。
- 下载侧已排入路线图（跨版本，与 spec 无关）：Range 多线程分段下载与断点续传、
  SNAPSHOT 时间戳版本解析（`~/.m2/snapshots`）；另有 zip/war/ear `.diff` 增量补丁与
  Windows 原生支持等既有路线图项，见 [release-v0.0.1.md](release-v0.0.1.md)。

## 边界决策

1. **不做命令行覆盖**：`main`/运行时/引擎定制统一在 spec 内声明（`[app] main`、
   `[app] runtime`、`[app] engine` 与 `[runtime]`/`[engine]` 段），不提供
   `--main-class=`/`--jvm=`/`--engine=` 之类的命令行参数；旧命名 `[jvm]` 段与
   `[app] java` 键已移除（视为未知段/未知键告警）。
2. **`[args]` 不做简写/解析**：不支持 `key = value → --key=value` 之类的转换；`-k=v`、
   `--k v`、位置参数等一律原样透传，由应用自行解释。
3. **行号告警已实现**：未知段/未知键/格式错误会在 stderr 输出 `line N: ...` 告警并被忽略。
