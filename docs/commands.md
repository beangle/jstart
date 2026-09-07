# 命令详解

jstart 0.0.1 提供四个子命令。命令名可以省略（默认 `run`）；选项与目标的位置不敏感，
`--xxx=value` 形式。未被 jstart 消费的参数进入 `run` 的透传列表。

## 通用

```text
jstart [options] <command> <target> [args...]
```

选项：

| 选项 | 说明 |
|------|------|
| `--local=<dir>` | 本地仓库，默认 `~/.m2/repository`；repo 命令里是"目标仓库" |
| `--source=<dir>` | 仅 repo 命令：源仓库，默认 `~/.m2/repository`，须与 `--local` 不同 |
| `--remote=<urls>` | 逗号分隔的远程仓库；默认阿里云 public、华为云 maven、Maven Central |
| `--preferwar` | gav 目标优先尝试 war 打包（对应原 sas.sh 场景） |
| `--quiet` / `-q` | 关闭下载/过程输出（错误仍由退出码体现） |
| `-h` / `--help` | 帮助 |
| `-V` / `--version` | 版本 |

退出码约定：

| 码 | 含义 |
|----|------|
| 0 | 成功 |
| 1 | 目标无法获取、依赖缺失、repo 源缺失或与 local 相同 |
| 2 | 缺少目标等用法错误（打印 usage） |
| 其他 | `run` 直接继承 java 的退出码（exec 后即 java 自身） |

## run —— 解析并启动

```text
jstart [options] run <target> [args...]
```

流程：解析目标 → 准备依赖 → 读 `Main-Class` → `execvp` 把自身替换为 java：

```text
java [jvm-args] -cp <classpath> <Main-Class> [app-args...]
```

参数分配：

- `-D...` / `-X...` 开头的参数交给 JVM；
- 其余（`--port=8080`、普通位置参数等）原样传给应用，顺序保持；
- 需在 classpath 前置追加路径时用环境变量 `CLASSPATH_EXTRA`（或小写
  `classpath_extra`，小写优先）。

示例：

```bash
jstart run /path/to/app.jar --port=8080 --path=/base
jstart run org.beangle.sqlplus:beangle-sqlplus:0.0.46 data.xml
jstart --local=/opt/repo --quiet run app.jar --port=9090
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

## repo —— 离线仓库整合

```text
jstart [options] repo <target> [--source=<dir>]
```

对应原 `org.beangle.boot.launcher.Repo`。target 必须是**已存在于本地**的 jar/war/
解压目录/文本依赖文件。逻辑：

1. 解析 target 的依赖描述；
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
| `/path/to/app.war` | war，读取 `WEB-INF/classes/...` 依赖描述 |
| `/path/dir` | 解压后的 war 目录 |
| `/path/deps.txt` | 普通文本，逐行当作依赖描述（便于调试） |
| `group:artifact:version` | gav；含 `:` 且无 `/`、`\` 时识别为 gav |
| `gav://group:artifact:version` | 显式 gav |
| `http(s)://host/path/app.jar` | 按主机路径缓存到本地仓库后使用 |
