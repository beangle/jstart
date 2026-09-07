# 命令详解

jstart 0.0.1 提供五个子命令：`run` / `resolve` / `classpath` / `info` / `repo`。
命令名可以省略（默认 `run`）；选项与目标的位置不敏感，`--xxx=value` 形式。
未被 jstart 消费的参数进入 `run` 的透传列表。

## 通用

```text
jstart [options] <command> <target> [args...]
```

选项：

| 选项 | 说明 |
|------|------|
| `--local=<dir>` | 本地仓库，默认 `~/.m2/repository`；SNAPSHOT 时间戳构件默认在独立的 `~/.m2/snapshots`（不混合），显式给定时也定位到该目录下的快照路径；repo 命令里是"目标仓库" |
| `--source=<dir>` | 仅 repo 命令：源仓库，默认 `~/.m2/repository`，须与 `--local` 不同 |
| `--remote=<urls>` | 逗号分隔的远程仓库；默认阿里云 public、华为云 maven、Maven Central |
| `--preferwar` | gav 目标优先尝试 war 打包（对应原 sas.sh 场景） |
| `--jobs=N` | 并行下载并发数，默认 10；`1` 为串行下载 |
| `--print` | 仅 run：准备完成后打印将执行的命令行（逐参数 shell 引号），不 exec |
| `--quiet` / `-q` | 关闭下载/过程输出（错误仍由退出码体现） |
| `-h` / `--help` | 帮助 |
| `-V` / `--version` | 版本 |

退出码约定：

| 码 | 含义 |
|----|------|
| 0 | 成功 |
| 1 | 目标无法获取、依赖缺失、repo 源缺失或与 local 相同 |
| 2 | 缺少目标等用法错误（打印 usage） |
| 其他 | `run` 直接继承被启动应用的退出码（exec 后即应用自身，当前为 java） |

## 本地仓库与快照库（不混合）

jstart 维护**两个互不混合的本地目录**，取决于构件类型：

| 目录 | 内容 | 默认位置 |
|------|------|----------|
| 本地仓库 | release/普通构件与 `.sha1`（含 `-SNAPSHOT` 字面文件），maven2 布局 `g/a/v/a-v.jar` | `~/.m2/repository`（`--local=` 覆盖） |
| 快照库 | SNAPSHOT **时间戳**构件 `a-1.0-<yyyyMMdd.HHmmss>-<build>.jar`，**全部带时间戳** | `~/.m2/snapshots`（独立，不与 repository 混合） |

- release 类构件只进本地仓库，**不会**出现在快照库；
- SNAPSHOT 时间戳构件只进快照库，**不会**与 repository 混合存放——本地判定"是否
  已是最新"只需看快照库内时间戳文件名（字符串即时间序），命中即用，不比较 mtime、
  不查远端；
- 显式 `--local=<dir>` 时快照时间戳文件也定位到该目录下对应快照路径（对齐 boot：
  显式给出 base 后不再另设 `~/.m2/snapshots`），但两者仍按 maven 发布/快照布局区分
  存放，文件名互不覆盖。

## run —— 解析并启动

```text
jstart [options] run <target> [args...]
```

流程：解析目标 → 准备依赖 → 读 `Main-Class` → `execvp` 把自身替换为运行时
（jar 目标 exec 应用 `Main-Class`；war 目标 exec 内置引擎 Bootstrap，见
[war-engine.md](war-engine.md)）：

```text
java <runtime-options> -cp <classpath> <Main-Class> [app-args...]        # jar
java <runtime-options> -cp <classpath> org.beangle.sas.engine.tomcat.Bootstrap \
     --base=<base> [--port=8080 --path=/ ...]                           # war
```

target 为 launch spec（`.launch`/`.jstart`，见 [launch-spec.md](launch-spec.md)）时，
主类（`[app] main`）、运行时/解释器可执行文件（`[app] runtime`）、运行时参数
（`[runtime]` 段）与应用参数（`[args]` 段）取自 spec；命令行上追加的参数排在 spec
之后（`-D`/`-X` 开头归运行时）。spec 声明 `[deps]` 时它是依赖唯一来源，否则回退
读取 entry 内置依赖清单。

参数分配：

- `-D...` / `-X...` 开头的参数归运行时（java 即 JVM 参数）；
- 其余（`--port=8080`、普通位置参数等）原样传给应用，顺序保持；
- 需在 classpath 前置追加路径时用环境变量 `CLASSPATH_EXTRA`（或小写
  `classpath_extra`，小写优先）。

war 目标（本地 `app.war`、gav/url 落盘为 `.war`）自动进入内置引擎流程：解析并
爆炸到 `<base>/webapps/<ctx>`（`base` 默认 `${TMPDIR:-/tmp}/jstart-sas`，可用
`--base=` 覆盖；`--path=` 决定 contextPath，缺省 `ROOT`），classpath 为爆炸目录的
`WEB-INF/classes`+`WEB-INF/lib`+应用依赖+引擎依赖，然后 exec
`org.beangle.sas.engine.<name>.Bootstrap`。引擎依赖有内置默认目录（tomcat 三件套 /
undertow 十四件套，等价 sas.sh 两个分支），需要固定或改版本时用 launch spec 的
`[engine]` 段显式罗列（权威，不依赖内置行）；选择引擎用 `[app] engine = tomcat|undertow`
（war 缺省 tomcat）。
war 的引擎模式只读取 `--path=`/`--base=` 用于爆炸布局，其余参数（含 `--port=`）
原样透传给引擎——详见 [war-engine.md](war-engine.md)。

`--print`：不 exec，把将执行的命令打印到 stdout（逐参数 POSIX 单引号，可直接复制
执行），用于审计与调试：

```bash
jstart run --print app.launch
jstart run --print app.jar --port=8080
```

示例：

```bash
jstart run /path/to/app.jar --port=8080 --path=/base
jstart run org.beangle.sqlplus:beangle-sqlplus:0.0.46 data.xml
jstart --local=/opt/repo --quiet run app.jar --port=9090
jstart run /path/to/app.war --port=8080 --path=/base   # 内置 tomcat 引擎
jstart run --print app.launch                          # spec：war 时含 [engine] 段
```

## resolve —— 只准备依赖环境

```text
jstart [options] resolve <target>
```

下载/校验依赖后把**应用绝对路径**打到 stdout（供脚本捕获），退出码表示依赖是否齐备：

```bash
app=$(jstart --quiet resolve /path/to/app.jar)   # exit=0 才使用
```

- war/gav 目标同样适用（`--preferwar` 控制 gav 取 jar 还是 war）。
- 依赖有缺失时仍会打印路径，但退出码为 1（对齐原 AppResolver 行为），缺失清单打到
  stderr。

## classpath —— 输出 Main-Class@classpath

```text
jstart [options] classpath <target>
```

依赖就绪后输出 `Main-Class@classpath`（`@` 前为 Manifest Main-Class，无则 `none`），
适合 launch.sh 式脚本解耦：

```bash
info=$(jstart --quiet classpath "$app")
main=${info%@*}
cp=${info#*@}
exec java -cp "$cp" "$main" "$@"
```

classpath 组成顺序：`CLASSPATH_EXTRA` → 应用 jar（或解压 war 的
`WEB-INF/classes` + `WEB-INF/lib/*.jar`）→ 各依赖本地路径。

## info —— 输出结构化信息

```text
jstart [options] info <target>
```

与 `resolve` 相同的准备语义（解析 → 下载缺失依赖 → 校验），齐备后把结构化信息
打到 stdout，供审计与 IDE/CI 集成；缺件时与 `resolve` 一致打 `Missing: ...` 并 exit 1。

输出为稳定的 `key: value` 文本，每个依赖一行 `dep <n>: <kind> <raw> -> <path> (<bytes> bytes)`：

```text
target: /path/to/app.jar
entry: /path/to/app.jar
app: /path/to/app.jar
type: jar
main: org.beangle.app.Main
local: /home/user/.m2/repository
snapshots: /home/user/.m2/snapshots
remotes: https://maven.aliyun.com/repository/public,...,https://repo1.maven.org/maven2
deps: 2
dep 1: gav org.slf4j:slf4j-api:2.0.17 -> /home/user/.m2/repository/org/slf4j/slf4j-api/2.0.17/slf4j-api-2.0.17.jar (69908 bytes)
dep 2: http https://repo.example.com/lib.jar -> /home/user/.m2/repository/repo.example.com/lib.jar (2826 bytes)
```

- `kind`：`gav`（maven 构件，命中本地快照库时 `path` 为时间戳文件）/ `local` / `http`；
- `type`：`jar`/`war`/`dir`（解压目录）/`file`（其它本地文件）；
- launch spec target 时 `entry`/`main` 取自 spec，其余字段一致；
- 脚本用 `grep '^main: '`、`grep '^dep '` 等按前缀取行即可。

## repo —— 离线仓库整合

```text
jstart [options] repo <target> [--source=<dir>]
```

对应原 `org.beangle.boot.launcher.Repo`。target 必须是**已存在于本地**的 jar/war/
解压目录或 launch spec（其 `entry` 必须是本地文件/目录）。
逻辑：

1. 解析 target 的依赖描述（war/spec 的 `[engine]` 引擎依赖**不参与**整合，见
   [war-engine.md](war-engine.md)）；
2. 只处理 gav 构件：`--local` 仓库已有则跳过；
3. 缺失的从 `--source` 仓库复制 jar 与 `.sha1`（源里有才复制）；
4. 全部齐备则输出 `--local` 仓库基目录并 exit 0；否则打 `Missing: ...` 并 exit 1。

约束：

- 默认 `--local` 与 `--source` 都是 `~/.m2/repository`，二者相同（按 realpath 归一）
  会直接报错退出；
- 本地文件行、http 行不参与复制。

示例：

```bash
# 在能联网的机器上，把应用依赖集齐到离线目录
jstart --quiet repo /path/to/app.jar --local=/opt/offline-repo

# 校验目标离线目录内容
jstart --local=/opt/offline-repo --quiet resolve /path/to/app.jar
```

## 目标（target）形态

| 形态 | 说明 |
|------|------|
| `/path/to/app.jar` | 瘦 jar，内含依赖描述（无描述时按自包含 jar 处理） |
| `/path/to/app.war` | war：`resolve`/`repo` 读取 `WEB-INF/classes/...` 依赖描述；`run` 走内置引擎流程（见 [war-engine.md](war-engine.md)） |
| `/path/dir` | 解压后的 war 目录 |
| `/path/deps.txt` | **不支持**：普通文本文件不再作为依赖清单 target，请把依赖写进 jar/war 内置描述或 launch spec 的 `[deps]` |
| `/path/app.launch` | launch spec：ini 式声明 main/entry/runtime/args/可选 [deps]/[engine]，`run` 的声明式目标（见 [launch-spec.md](launch-spec.md)） |
| `group:artifact:version` | gav；含 `:` 且无 `/`、`\` 时识别为 gav |
| `gav://group:artifact:version` | 显式 gav |
| `http(s)://host/path/app.jar` | 按主机路径缓存到本地仓库后使用 |
