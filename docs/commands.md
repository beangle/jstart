# 命令详解

jstart 0.0.1 提供七个子命令：`run` / `resolve` / `classpath` / `info` / `repo` / `fetch` / `stop`。
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
| `--from=<version>` | fetch 命令与 native（tar.gz）gav 目标：增量补丁的基线版本；缺省取本地（含快照库）里最接近的较低版本 |
| `--base=<dir>` | run/stop：**base 根目录**，替换缺省的 `/var/tmp/jstart`（不是拼在默认根下）；组件的运行目录是 `<base>/<组件键>`（见"组件 base 与 pid 文件"） |
| `--instance=<name>` | run/stop：命名组件目录（`<根>/<name>-<组件指纹>`），同一组件跑多副本时用（等价于换一个 `--base`） |
| `--main=<class>` | run/classpath/info：指定 java 主类，优先于 `[app] main` 与 jar 内 `MANIFEST.MF` 的 `Main-Class`；只对 jar/gav-jar/解压目录生效，war/native 目标告警忽略 |
| `--timeout=<sec>` | stop：SIGTERM 后等待进程退出的秒数，缺省 15 |
| `--force` | run：base 上的实例仍在运行时也照常启动（覆盖旧 pid 文件）；stop：超时后改用 SIGKILL |
| `--remote=<urls>` | 逗号分隔的远程仓库；默认阿里云 public、华为云 maven、Maven Central；fetch 命令下是发行仓库基地址，默认 `https://sas.openurp.net/sas/repo/native` |
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
| 1 | 目标无法获取、依赖缺失、repo 源缺失或与 local 相同；run 检测到同一实例已在运行 |
| 2 | 用法错误：缺少目标（打印 usage）、`--print` 用于非 run、`--main` 值为空或不是类名 |
| 3 | stop：目标实例未运行（pid 文件不存在、进程已退出，或 pid 已被复用）；残留 pid 文件会被清掉 |
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

流程：解析目标 → 准备依赖 → 写 pid 文件（见"组件 base 与 pid 文件"）→ 定主类 →
`execvp` 把自身替换为运行时
（jar 目标 exec 应用 `Main-Class`；war 目标 exec 内置引擎 Bootstrap，见
[war-engine.md](war-engine.md)；native tar.gz 目标 exec 包内可执行文件，见下文
“native（tar.gz）目标”）：

```text
java <runtime-options> -cp <classpath> <Main-Class> [app-args...]        # jar
java <runtime-options> -cp <classpath> org.beangle.sas.engine.tomcat.Bootstrap \
     --base=<base> [--port=8080 --path=/ ...]                           # war
<解压出的可执行文件> [args...]                                           # native tar.gz
```

主类按 **`--main` > launch spec `[app] main` > jar 内 `MANIFEST.MF` 的 `Main-Class`**
确定，三者都没有时报错 exit 1（提示 `--main=<class>`）。解压目录（没有 manifest）只能靠
前两者；主类可以来自依赖 jar，只要它在 classpath 上。`--main` 是 jstart 选项（本地消费、
不转发给应用），空值或明显不是类名（路径、url、逗号等）在启动前就以 exit 2 报错：

```bash
jstart run app.jar --main=com.example.Tool      # 覆盖 manifest 里的 Main-Class
jstart run app.jar --main=com.example.Tool --port=8080   # 其余参数照常透传
jstart --quiet --main=com.example.Tool classpath app.jar  # 脚本口径同步
```

> war 的主类由引擎 Bootstrap 决定（用 `[app] engine` 选引擎），native 用 `[app] exec`；
> 这两种目标上给 `--main`/`[app] main` 会告警忽略。主类不参与实例身份：同一个 target
> 换主类仍是同一个 base（要并行跑请配 `--instance`/`--base`）。

target 为 launch spec（`.jstart`，支持本地路径或 http(s) url，见
[launch-spec.md](launch-spec.md)）时，主类（`[app] main`）、运行时/解释器可执行
文件（`[app] runtime`）、运行时参数（`[runtime]` 段）与应用参数（`[args]` 段）
取自 spec；命令行上追加的参数排在 spec 之后（`-D`/`-X` 开头归运行时）。spec
声明 `[deps]` 时它是依赖唯一来源，否则回退读取 entry 内置依赖清单。

参数分配：

- `-D...` / `-X...` 开头的参数归运行时（java 即 JVM 参数）；
- 其余（`--port=8080`、普通位置参数等）原样传给应用，顺序保持；
- 需在 classpath 前置追加路径时用环境变量 `CLASSPATH_EXTRA`（或小写
  `classpath_extra`，小写优先）。

war 目标（本地 `app.war`、gav/url 落盘为 `.war`）自动进入内置引擎流程：解析并
爆炸到 `<base>/webapps/<ctx>`（`base` 是组件的运行目录 `<base 根>/<组件键>`，
根默认 `/var/tmp/jstart`，`--base=`/`--instance=`/`[app] base` 可换；
`--path=` 决定 contextPath，缺省 `ROOT`），classpath 为爆炸目录的
`WEB-INF/classes`+`WEB-INF/lib`+应用依赖+引擎依赖，然后 exec
`org.beangle.sas.engine.<name>.Bootstrap`。引擎依赖有内置默认目录（tomcat 三件套 /
undertow 十四件套，等价 sas.sh 两个分支），需要固定或改版本时用 launch spec 的
`[engine]` 段显式罗列（权威，不依赖内置行）；选择引擎用 `[app] engine = tomcat|undertow`
（war 缺省 tomcat），tomcat 可带版本后缀 `tomcat-11.0.24` 直接换内置 tomcat 版本，
`[engine]` 行内支持 `{tomcat.version}`/`{sas.version}` 占位符引用内置版本。
war 的引擎模式只读取 `--path=` 用于爆炸布局（`--base` 已是 jstart 的 base 选项，引擎
拿到的是注入的 `--base=<base>`；`[args]` 里的 `--base=` 会被丢弃），其余参数
（含 `--port=`）原样透传给引擎——详见 [war-engine.md](war-engine.md)。

`--print`：不 exec，把将执行的命令打印到 stdout（逐参数 POSIX 单引号，可直接复制
执行），用于审计与调试：

```bash
jstart run --print app.jstart
jstart run --print app.jar --port=8080
```

示例：

```bash
jstart run /path/to/app.jar --port=8080 --path=/base
jstart run org.beangle.sqlplus:beangle-sqlplus:0.0.46 data.xml
jstart --local=/opt/repo --quiet run app.jar --port=9090
jstart run /path/to/app.war --port=8080 --path=/base   # 内置 tomcat 引擎
jstart run --print app.jstart                          # spec：war 时含 [engine] 段
jstart run https://repo.example.com/app.jstart         # 远程 spec：下载后按 entry 解析
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
- native（tar.gz）目标复用 `fetch` 的取包逻辑并解压，输出的是**包内可执行文件绝对路径**
  （可直接 exec；见下文"native（tar.gz）目标"）。
- 依赖有缺失时仍会打印路径，但退出码为 1（对齐原 AppResolver 行为），缺失清单打到
  stderr。

## classpath —— 输出 Main-Class@classpath

```text
jstart [options] classpath <target>
```

依赖就绪后输出 `Main-Class@classpath`（`@` 前为主类，`--main`/`[app] main` 可覆盖
manifest；都没有则 `none`），
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
main source: manifest
local: /home/user/.m2/repository
snapshots: /home/user/.m2/snapshots
remotes: https://maven.aliyun.com/repository/public,...,https://repo1.maven.org/maven2
deps: 2
dep 1: gav org.slf4j:slf4j-api:2.0.17 -> /home/user/.m2/repository/org/slf4j/slf4j-api/2.0.17/slf4j-api-2.0.17.jar (69908 bytes)
dep 2: http https://repo.example.com/lib.jar -> /home/user/.m2/repository/repo.example.com/lib.jar (2826 bytes)
```

- `kind`：`gav`（maven 构件，命中本地快照库时 `path` 为时间戳文件）/ `local` / `http`；
- `type`：`jar`/`war`/`dir`（解压目录）/`native`（tar.gz 发行包）/`file`（其它本地文件）；
  `native` 时额外给出 `archive`（本地包路径）与 `root`（解压根目录），`app` 为可执行文件路径；
- `main source`：主类来自哪里 —— `cli`（`--main=`）/`spec`（`[app] main`）/`manifest`
  （jar 内 `Main-Class`）/`none`；排查"为什么跑了另一个类"时看这一行；
- launch spec target 时 `entry`/`main` 取自 spec，其余字段一致；
- 脚本用 `grep '^main: '`、`grep '^dep '` 等按前缀取行即可。

## repo —— 离线仓库整合

```text
jstart [options] repo <target> [--source=<dir>]
```

对应原 `org.beangle.boot.launcher.Repo`。target 必须是**已存在于本地**的 jar/war/
解压目录或 launch spec（只接受本地 `.jstart`，其 `entry` 必须是本地文件/目录；
不做联网下载）。
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

## fetch —— 下载目标（gav 优先增量补丁）

```text
jstart [options] fetch <target> [--from=<version>] [--remote=<base>] [--local=<dir>]
```

`fetch` 负责把目标取到本地，成功时把**本地绝对路径**打到 stdout。目标可以是 gav、
`http(s)` url 或本地文件：

- **gav**：从发行仓库（beangle native 仓库，maven2 布局）取构件，**native 的 tar.gz 与普通
  jar/war 都走这里**，增量补丁逻辑完全相同，区别只在"应用补丁"的方式。gav 支持 classifier，
  第五段是版本；
- **`http(s)://...`**：直接下载（带 `.sha1` 校验），按主机路径缓存到本地仓库；
- **本地文件**：原样输出其绝对路径（便于脚本统一走 `fetch` 取路径）。

```bash
# 直接下载一个 url（缓存后打印本地路径）
jstart fetch https://host/path/app-1.0.tar.gz

# 本地文件原样返回绝对路径
jstart fetch ./app-1.0.tar.gz
```

取 gav 时支持 classifier，第五段是版本：

```bash
# org.beangle.ems:beangle-ems-portal 的 4.20.14-SNAPSHOT 版 linux-amd64 tar.gz
jstart fetch org.beangle.ems:beangle-ems-portal:tar.gz:linux-amd64:4.20.14-SNAPSHOT

# 普通 war/jar 同样支持增量：本地有 4.20.13 的 war 时只下 4.20.13_4.20.14 的补丁
jstart fetch org.beangle.ems:beangle-ems-portal:war:4.20.14 --from=4.20.13
jstart fetch org.beangle.ems:beangle-ems-portal:jar:4.20.14 --from=4.20.13
```

构件类型与"应用补丁"的差异（其余流程一致：探测 → 下载 → 校验 `sha1` → 重建 → 复核）：

| 构件 | 补丁名 | 应用方式 |
|------|--------|----------|
| `tar.gz` / `tgz` | `<a>-<旧>_<新>[-<classifier>].tar.gz.diff` | 基线 `gunzip` → `bspatch` → `gzip -n -6`（压缩流之间 diff 没有节省，所以比对解压后的 tar） |
| `jar` / `war` 等 | `<a>-<旧>_<新>.<packaging>.diff` | 构件本身可比对，直接 `bspatch`，不解压不重压 |

> 基线按**同一打包类型**取：war 的增量需要本地存在旧版本的 war（旧 jar 不算基线），
> 找不到基线或没有补丁就整包下载，都不算错误。

本地落盘沿用 jstart 的两库约定：**SNAPSHOT 版本进快照库**（默认 `~/.m2/snapshots`），
**正式版进本地仓库**（默认 `~/.m2/repository`，即 `--local`），两者不混合。

流程：

1. 本地已有就直接用：SNAPSHOT 先看快照库里时间戳最新的一份，再看快照库里的
   `-SNAPSHOT` 字面文件；正式版看 `--local` 仓库。命中且 `.sha1` 校验通过即返回（exit 0）；
2. 确定基线版本：`--from=<version>` 优先；缺省扫描 `--local` 仓库（正式版）与快照库
   （SNAPSHOT），取比目标版本低的最高版本；
3. 探测 `<仓库>/<g>/<a>/<version>/<a>-<基线>_<版本>[-<classifier>].<packaging>.diff`
   （HEAD，SNAPSHOT 用不带时间戳的别名；native 的 tar.gz 补丁名带 classifier，
   maven 侧 war/jar 的补丁名不带）。**没有补丁是正常情况**，转整包下载；
4. 有补丁时：下载补丁与目标 `.sha1` → 校验补丁 `.sha1`（远端有才校验）→ 重建 → 与目标
   `.sha1` 比对。重建方式按打包类型区分：
   - `tar.gz`/`tgz`：补丁比对的是**解压后的 tar**（压缩流之间 diff 几乎没有节省），
     所以本地基线先 `gunzip`，打完补丁再按 `tar -z` 的参数 `gzip -n -6` 压回去；
   - `jar`/`war` 等：构件本身就是可比对的文件，直接打补丁，不解压不压缩；
   任一环节失败（补丁损坏、本地没有基线、重建结果不符）都回退整包下载，不会失败退出；
5. 整包下载同样带 `.sha1` 校验，损坏则换下一个 `--remote`；全部失败才 exit 1。

- 默认 `--remote` 为 `https://sas.openurp.net/sas/repo/native`（逗号分隔可给多个，
  按序尝试，与 `resolve` 的 maven 镜像列表不同：这里不追加 Maven Central）；
- 依赖宿主命令：`curl` 下载，增量路径另需 `bzip2`（解压补丁里的 bzip2 流），
  tar.gz 还需要 `gzip`；缺对应命令时只走整包下载；
- 打补丁优先用系统 `bspatch`：`PATH` 上有就用（`bspatch <old> <new> <patch>`），
  运行失败或产物尺寸与补丁头声明的输出长度不符时，自动回退到内置实现（只需 `bzip2`）。
  用 `JSTART_BSPATCH=<path>` 指定特定 bspatch，`JSTART_BSPATCH=builtin`
  （`none`/`internal` 同义）强制内置实现；CentOS 8 等未打包 bspatch 的发行版直接用内置实现；
- `--quiet` 只输出最终本地路径（供脚本捕获），进度与回退原因打到 stderr/stdout。

示例：

```bash
# 显式基线 + 自建仓库，脚本里取路径
artifact=$(jstart --quiet fetch org.beangle.ems:beangle-ems-portal:tar.gz:linux-amd64:4.20.14-SNAPSHOT \
  --from=4.20.13 --remote=https://sas.openurp.net/sas/repo/native --local=~/.m2/repository)
```

**与 `resolve`/`run` 的关系**：`fetch` 只负责"把目标取到本地"。`resolve`/`run` 遇到 gav 或
本地 `*.tar.gz`（native 发行包）时**复用同一套取包逻辑**（gav 含上面的增量补丁与 sha1 校验；
url/本地文件同 `fetch`），然后解压并定位包内可执行文件，见下节。

## native（tar.gz）目标 —— 取包、解压、运行

GraalVM native-image 的发行包是 tar.gz（约定布局 `<name>/bin/<exe>` + `<name>/lib/...`）。
jstart 把它当作可运行目标：**取包 → 解压 → exec 包内可执行文件**，用户参数按序附加在
可执行文件之后（native 没有 JVM，也就没有单独的"运行时参数"）。

```bash
# gav：走发行仓库取包（有增量补丁就只下补丁），解压后 exec 包内可执行文件
jstart run org.beangle.ems:beangle-ems-portal:tar.gz:linux-amd64:4.20.14-SNAPSHOT --port=8080 --path=/base

# 本地包同样支持：默认解压到 /var/tmp/jstart/<包名>-<指纹>/app，二次运行直接复用
jstart run /path/to/beangle-ems-portal-4.20.14-linux-amd64.tar.gz --port=8080

# 脚本里取可执行文件路径（--quiet 下 stdout 只有路径，适合命令替换）
boot=$(jstart --quiet resolve org.beangle.ems:beangle-ems-portal:tar.gz:linux-amd64:4.20.14-SNAPSHOT)
"$boot" --port=8080

# 先看将执行的命令行（逐参数引号），不 exec
jstart run --print org.beangle.ems:beangle-ems-portal:tar.gz:linux-amd64:4.20.14-SNAPSHOT --port=8080
```

行为要点：

- **取包**：取包就是 `fetch` 的职责——gav 走发行仓库（默认 `--remote`，`--from` 指定增量
  基线），`http(s)://...tar.gz` url 直接下载（按主机路径缓存），本地文件原样使用；
- **解压**：`tar -xzf` 解压到组件的 base 下（`<base>/app`），目录内的 `.jstart.stamp` 记录
  包的尺寸+mtime：标记匹配即复用，包内容变化（如增量重建后）自动重解。解压先写独立临时目录、
  再整体改名就位，因此并发/强杀残留也不会看到半个目录；旧目录改名挪走后清理，正在运行的
  实例仍使用旧 inode；
- **解压位置**：`<base>/app`，其中 base 是组件目录 `<base 根>/<组件键>`，根默认
  `/var/tmp/jstart`（组件目录 0700，仅本用户可写）。比 `/tmp` 更适合放运行产物：通常是
  真实文件系统（非 tmpfs）、不挂 `noexec`，且 `systemd-tmpfiles` 的清理周期更长（默认
  30 天 vs 10 天）。**不会**解压到包（jar/tar.gz）所在目录，避免写脏本地 maven 仓库或
  用户数据目录；根无法准备（不存在且创建失败、不是目录）时直接报错，用 `--base=<dir>`
  指定别处：

  ```bash
  # 解压/运行到指定根（同一组件再跑一个副本也要换根）
  jstart run --base=/tmp/jstart-native org.beangle:app:tar.gz:linux-amd64:1.0 --port=8080
  jstart run --base=~/.cache/jstart/app1 org.beangle:app:tar.gz:linux-amd64:1.0 --port=8081
  ```

  > 换 `--base` 时的三个注意点：指定 `/tmp` 时它可能以 `noexec` 挂载（解压出的可执行
  > 文件会被拒绝执行）、可能是 tmpfs（解压体积通常是包的 2–3 倍，占内存）、且清理更激进
  > （10 天）。**长期运行的服务建议用默认根 `/var/tmp/jstart`，或 `~/.cache/jstart/<应用>`。**
  > 解压目录不随进程退出删除（exec 后进程即应用，运行期还要用 lib/ 等），需要回收请自行清理；
  > 目录内的 `.jstart.stamp` 标记留在原地，删掉解压目录后会按需重解。即使整个
  > `/var/tmp/jstart` 被清理，下次运行也会重新解压，无需干预。
- **base ≠ 参数**：base 只认组件（target）与 `--base`/`--instance`/`[app] base`，**不认应用
  参数**；一个 base 只跑一个实例，多副本用多 base。见下节"组件 base 与 pid 文件（run/stop）"；
- **不覆盖用户目录**：目标目录存在但**没有** jstart 的 `.jstart.stamp` 标记（不是我们解压
  出来的，例如用户手工解压的目录）时拒绝覆盖并报错，数据保持原样；请先自行清理，或直接用
  `[app] exec` 指到你手工解压的可执行文件；
- **可执行文件**：launch spec `[app] exec=` 显式指定（相对解压根目录，如 `demo-1.0/bin/demo`）；
  缺省按 `<root>/bin/<artifactId>`、`bin/` 下唯一可执行文件、树内唯一可执行文件（≤3 层）、
  名称匹配 artifactId 的顺序探测；判不定时报错并列出候选，提示用 `[app] exec=` 指定。
  打包丢了执行位时按 `bin/` 下唯一常规文件兜底并补上执行位；
- **参数**：spec `[args]` 段在前、命令行参数在后，全部作为 argv 附加在可执行文件之后
  （`-D`/`-X` 也归应用，不做 JVM 参数拆分）；`[runtime]` 段与 `[app] runtime` 对 native 无意义，
  给出时告警忽略；
- **子命令**：`resolve` 输出可执行文件绝对路径（供脚本 exec）；`run` 解析后 exec 它（进程即
  应用，无父子等待）；`info` 输出 `type: native` 与 `archive`/`root`；`classpath` 对 native
  无意义（exit 2，提示改用 `resolve`）；
- **依赖**：native 包内没有依赖清单，需要额外依赖时用 spec `[deps]` 段显式罗列（语义不变）。

## 组件 base 与 pid 文件（run/stop）—— 一个 base 一个实例

`run`/`stop` 以**组件的 base 目录**为单位：`run` 在 exec **之前**把 pid 写进 `<base>/app.pid`
（exec 之后本进程就是应用，pid 不变，所以文件里就是应用的 pid），`stop` 读同一个文件停应用。

base 一词有两层，记住这两行就够：**base 根（root）**默认 `/var/tmp/jstart`，`--base=<dir>`
整体替换它（不是拼在默认根下）；**组件目录（base）**= `<根>/<组件键>`，jstart 自动创建并
按用户隔离。

**实例身份 = 组件（target）+ base，与应用参数无关**：

| 位置 | 粒度 | 说明 |
|------|------|------|
| `<base 根>` | 可共用 | 缺省 `/var/tmp/jstart`（01777 sticky，同 `/tmp`，多个用户/组件可共存），`--base=<dir>` 整体替换它 |
| `<root>/<组件键>` | 一个组件一份 | 组件目录，jstart 创建为 0700 并校验属主（同一 target 永远同一个目录） |
| `<base>/app.pid` | 一个 base 一份 | `run` 写、`stop` 读；检测到真实进程仍在运行即拒绝重复启动 |
| `<base>/app/` | 一个 base 一份 | native（tar.gz）的解压树（`.jstart.stamp` 在内），标记匹配时复用 |
| `<base>/webapps/<ctx>/` | 一个 base 一份 | war 的爆炸目录（引擎拿到的 `--base` 就是组件目录） |

- **组件键**：target 短名 + 短指纹（本地路径先绝对化；不含任何应用参数），因此同一个 target
  无论参数怎么变都落在同一个组件目录，不同 target 不会碰撞；
- **组件目录始终 0700、属主本人**：根可以是共享目录（默认根由 jstart 建成 01777 sticky），
  但单个实例的运行状态只对本用户可读写；目录被他人占用或换成符号链接时直接报错，不做兜底；
- **一个 base 只能跑一个实例**：同一个 target 再 `run`（哪怕参数完全不同）会报
  `Already running`（exit 1）；`--force` 可覆盖；
- **要跑多个副本就给每个副本一个 base**：`--base=<dir>` 指定路径，或 `--instance=<name>`
  用命名组件目录（`<根>/<name>-<组件指纹>`），也可在 launch spec 里写
  `[app] base = <dir>`。副本之间各自解压/爆炸，互不干扰；
- **`stop` 不需要应用参数**：`jstart stop <target>`（或 `--base=`/`--instance=` 指定同一个 base）
  即可；多给的参数会被忽略并提示。base 对不上时报 `nothing to stop`（exit 3）。

```bash
# 同一份工件跑两个副本：--instance 命名组件目录（默认根下），参数只影响应用本身
jstart run /opt/app/portal.tar.gz --instance=portal-a --port=8081 &
jstart run /opt/app/portal.tar.gz --instance=portal-b --port=8082 &

# 或整个换根：/srv/jstart/<组件键>、/srv/jstart2/<组件键>
jstart run /opt/app/portal.tar.gz --base=/srv/jstart --port=8083 &
jstart run /opt/app/portal.tar.gz --base=/srv/jstart2 --port=8084 &

# 停止：只认组件 + base，参数无需重复（写错/多写都不影响）
jstart stop /opt/app/portal.tar.gz --instance=portal-a
jstart stop /opt/app/portal.tar.gz --base=/srv/jstart2

# 同一个 base 重复启动会被拒绝（参数不同也一样）
jstart run /opt/app/portal.tar.gz --instance=portal-a --port=9999  # Already running
```

`stop` 行为：

- 读 pid 文件 → SIGTERM → 每 100ms 轮询，进程退出（含僵尸态）即成功，删掉 pid 文件并清掉
  组件目录下的空目录（空的组件目录本身也会删掉，base 根不动；应用自留的非空内容与解压
  树保留，供下次启动复用）；
- `--timeout=<sec>`（默认 15）后仍未退出：报错 exit 1 并保留 pid 文件；加 `--force` 则改发
  SIGKILL；
- pid 文件不存在、pid 已不存在、或 pid 的 start 时间与记录不符（pid 被系统复用）：判为
  "未运行" exit 3，残留文件会被清掉；
- `stop` **不取包、不解析依赖**，因此包被清理、仓库不可达时也能停止正在运行的实例。

其他说明：

- base 根不存在会自动创建（`--base` 给的根只要求是目录，不强制 0700；缺省根
  `/var/tmp/jstart` 建成 01777 sticky）；组件目录则是 jstart 创建的 0700 私有目录，
  属主/权限/符号链接不符即报错；`--base` 里可用 `~`/`${VAR}`；
- launch spec 可用 `[app] base = <dir>` 固定 base（见 [launch-spec.md](launch-spec.md)），
  此时 `run`/`stop` 都不需要额外参数；
- 缺省根无法准备（不存在且创建失败、不是目录）时直接报错，用 `--base=<dir>` 指定别处；
- 应用被 `kill -9` 等强杀时 pid 文件会残留，下次 `stop`/`run` 会按"进程已不存在"处理；
- 一个 base 一份解压/爆炸，多副本 = 多 base（代价是各存一份解压产物）；jar 目标没有解压/
  爆炸产物（jar 本体只读、可共用），但同样按 base 区分实例。

## 目标（target）形态

| 形态 | 说明 |
|------|------|
| `/path/to/app.jar` | 瘦 jar，内含依赖描述（无描述时按自包含 jar 处理） |
| `/path/to/app.war` | war：`resolve`/`repo` 读取 `WEB-INF/classes/...` 依赖描述；`run` 走内置引擎流程（见 [war-engine.md](war-engine.md)） |
| `/path/dir` | 解压后的 war 目录 |
| `/path/app.tar.gz` | native 发行包（GraalVM）：解压到 `<base>/app`（base = `<根>/<组件键>`，根默认 `/var/tmp/jstart`，`--base` 可改）后 exec 包内可执行文件，参数附加在其后（见"native（tar.gz）目标"） |
| `/path/deps.txt` | **不支持**：普通文本文件不再作为依赖清单 target，请把依赖写进 jar/war 内置描述或 launch spec 的 `[deps]` |
| `/path/app.jstart` | launch spec：ini 式声明 main/entry/runtime/args/可选 [deps]/[engine]，`run` 的声明式目标（见 [launch-spec.md](launch-spec.md)） |
| `group:artifact:version` | gav；含 `:` 且无 `/`、`\` 时识别为 gav |
| `gav://group:artifact:version` | 显式 gav |
| `group:artifact:tar.gz:<classifier>:version` | native 发行包 gav：走发行仓库取包（含增量补丁）后解压运行 |
| `http(s)://host/path/app.tar.gz` | native 发行包 url：直接下载（按主机路径缓存）后解压运行 |
| `http(s)://host/path/app.jar` | 按主机路径缓存到本地仓库后使用 |
| `http(s)://host/path/app.jstart` | 远程 launch spec：下载并缓存后解析，`run` 按 spec 的 entry 继续 |
