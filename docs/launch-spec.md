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
| `[runtime]` | 行列表 | 每个非注释行是一个运行时参数（Java 的 `-D`/`-X`/`--add-opens`、Python 的 `-O` 等），按书写顺序拼接 |
| `[args]` | 行列表 | 每个非注释行是一个应用参数，**整行**作为一个 argv：不切分、不展开变量，值含空格可直接书写 |
| `[deps]` | 行列表 | 可选。每行语法与依赖描述文件一致（gav/本地文件/远程 url） |

### 语义约定

- `[deps]` **存在**时它是依赖的唯一来源，不再读取 entry 内置的
  `META-INF/beangle/dependencies`（本地开发覆盖内置清单的手段，也保持"显式依赖"约束）；
- `[deps]` **不存在**时自动回退读取 entry 内的依赖描述（jar/war/解压目录各位置规则
  与现有 `resolveDependencies` 完全一致）；
- `[app] main` 与 entry 内 Manifest `Main-Class` 都缺失时，`run` 报
  `Cannot find Main-Class` 并退出 1（war 的引擎启动属另行设计，见"范围与规划"）；
- 未知段/未知键：告警并忽略（向前兼容）；重复键取最后值，列表行按出现顺序追加；
- `[args]`/`[runtime]` 不做 shell 语义：值与注释由文件行界定，杜绝引号转义问题。
- **参数一律不做解析**：`[args]` 每行原样作为一个 argv；`run` 命令行上无法识别的参数
  （如 `--port=8080`、`--k v`、`-k=v`）同样原样透传，jstart 不解释键值结构——写法众口
  难调（`-k=v` 与 `--k v` 并存），统一交给应用自行处理；`-D`/`-X` 开头归运行时
  （java 即 JVM 参数，与非 spec 的 jar 目标一致）。
- **运行时定制只在 spec 内**：Java 主类用 `[app] main`、运行时参数用 `[runtime]` 段、
  运行时/解释器可执行文件用 `[app] runtime`；不提供 `--main-class=`/`--jvm=` 之类的
  命令行覆盖，避免同一参数在文件与命令行两处出现（试参数请直接改文件或加 `[args]` 行）。

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
- **war 引擎运行单独设计**：部分 war 自带 Main-Class（可直接 run）；不带时需要"指定
  引擎（如内嵌 undertow/tomcat）运行"，涉及引擎选择、端口/contextPath 等，另行设计，
  不在本文件范围。
- 下载侧已排入路线图（跨版本，与 spec 无关）：Range 多线程分段下载与断点续传、
  SNAPSHOT 时间戳版本解析（`~/.m2/snapshots`）；另有 zip/war/ear `.diff` 增量补丁与
  Windows 原生支持等既有路线图项，见 [release-v0.0.1.md](release-v0.0.1.md)。

## 边界决策

1. **不做命令行覆盖**：`main`/运行时定制统一在 spec 内声明（`[app] main`、`[runtime]`
   段、`[app] runtime`），不提供 `--main-class=`/`--jvm=...` 命令行参数；旧命名
   `[jvm]` 段与 `[app] java` 键已移除（视为未知段/未知键告警）。
2. **`[args]` 不做简写/解析**：不支持 `key = value → --key=value` 之类的转换；`-k=v`、
   `--k v`、位置参数等一律原样透传，由应用自行解释。
3. **行号告警已实现**：未知段/未知键/格式错误会在 stderr 输出 `line N: ...` 告警并被忽略。
