# War 引擎运行

war 没有 `Main-Class`，不能像 jar 那样 exec 应用主类；它必须交给一个 **servlet 容器
引擎**。jstart 的做法是把 war（文件或已解压目录）交给 spec 声明的 **`[engine] init`
命令**：它准备容器环境、写出**最终启动命令**后退出，jstart 再 exec 那条命令；最终
进程是容器，无父子等待。

`init` 是**命令行**，最简是单个可执行文件/脚本路径（`~` 与 `${VAR}` 会展开，且是**先
分词再展开**），也可直接带参数（如 `init = engine-creator tomcat-server`）；**不是 java 类**。
jstart 不做 shell 解释，也不解析引擎别名或内置引擎类映射。

```text
# 阶段 1：jstart 运行 [engine] init 命令（准备环境，短进程）
<init> --base=<base> --entry=<war|dir> \
       --engine-classpath-file=<file> --app-classpath-file=<file> \
       --local-repo=<dir> --entry-out=<file> [--app-jvm-arg=...] [args...]

# 阶段 2：init 命令把最终命令写入 --entry-out，jstart 读取并 exec（进程变为容器）
java <runtime-options> -cp <引擎 jar + 应用依赖 + WEB-INF/classes + WEB-INF/lib/*.jar>
     <容器 main> --base=<base> [args...]
```

**war 的解压与 docBase 布局由引擎（init 命令）负责**：jstart 不再自己爆炸 war，也不镜像
容器的布局公式，只把 `--base` / war 路径 / 两个 classpath 文件 / 透传参数交给 init 命令。完整协议
（argv 文件格式、`--entry` 语义、错误约定）见 [engine.md](engine.md)。

jstart **不内置任何引擎依赖目录**（连 tomcat 的 embed jar 清单也没有），以保持引擎中立：
spec 必须显式声明 `init` 命令与引擎 jar。声明了 `[engine]` 段的 spec 其启动模型即
`LaunchType.engine`（见 [launch-spec.md](launch-spec.md)）。

## 何时启用

`run` 的目标是 **launch spec**、且 spec 声明了 `[engine]` 段时启用（entry 为 war 或带
引擎声明的解压目录）。war **不能**作为 `run` 的裸目标（本地 `app.war`、`g:a:v`/`gav://`、
`http(s)://` url 都不行）：引擎、参数、base 都需要显式声明，而这正是 launch spec 的
职责；给裸 war 目标 `run` 会报错并提示写成 spec。最小的 war spec：

```ini
[app]
entry = /path/app.war        # 也可是 g:a:v:war 或 gav://...:war

[engine]                     # 必填：init 命令（入口）+ 引擎/容器 jar
init = engine-creator tomcat
org.beangle.bas:beangle-bas-engine:0.13.17
org.apache.tomcat.embed:tomcat-embed-core:11.0.21
org.apache.tomcat.embed:tomcat-embed-websocket:11.0.21

[args]
--port=8080
--path=/
```

```bash
jstart run app.jstart
```

`resolve`/`fetch`/`repo` **不受此限制**：它们仍直接接受 war 文件/gav，例如
`jstart resolve /path/app.war` 只解析 war 内置依赖并打印路径，不涉及引擎。

## docBase 布局（归引擎）

引擎按 `--base` + `--path` 推导 docBase（例如 beangle/bas 的 `Server.Config` 语义），
并在准备阶段把 war 解压到那里；jstart 只传参数，**不感知解压公式**。公式与重建/清理
时机见 [engine.md](engine.md)：

| 参数 | 布局 |
|------|------|
| `--path` 缺省或 `/` | `<base>/webapps/ROOT` |
| `--path=/a/b` | `<base>/webapps/a#b`（先归一化：去尾 `/`、折叠 `//`） |

- `base` 就是组件的运行目录 `<base 根>/<组件键>`：根默认 `/var/tmp/jstart`，用
  `--base=<dir>` 换根、launch spec 的 `[app] base`（根）/`[app] instance`（目录名）命名；
  `<base>/webapps/<ctx>` 是引擎解压出的 docBase（多副本各自指定一个 base）；
- 引擎每次准备时**重建** docBase（先删后解压）；容器关闭（shutdown hook）时会自行删除
  docBase，被 `kill -9` 留下的残骸由下一次运行清理；
- 同一 `base` 上运行相同 context path 会冲突（与 bas.sh 相同）：默认已按组件隔离，
  多副本请各自指定 `--base` 或 `[app] instance`；
- 无 `WEB-INF/classes` 的极简 war 会补一个空目录（引擎启动时要探测 classpath 上的
  目录资源，全是 jar 时 `getResource("")` 为 null）。

## 参数语义（例外解析）

引擎模式下 jstart 只**读取** `--base`（jstart 自己的 base 选项），其余一律原样透传：

- `--base=`：是 jstart 的 base 选项（`--base=` 或 launch spec `[app] base`，命令行优先），
  不再从 `[args]` 里读（`[args]` 里的 `--base=` 会被丢弃，避免与注入值冲突）；jstart
  统一以 `--base=<base>` 放在 init 命令参数首位；
- `--path=`：上下文路径，jstart **不读取**，原样交给 init 命令，引擎据此推导 docBase；
  缺省 `/`；
- `-D`/`-X` 开头的命令行参数与 `[runtime]` 段归 JVM，作为 `--app-jvm-arg` 交给 init 命令
  写进最终命令；
- `--port=8080` 等其余参数不读取、按序原样透传（端口由引擎消费，被占用时自动探测空闲
  端口或报错）。注意 **bas 引擎只消费 `--path/--port/--dev/--base`**，其余打印
  `ignore param` 后忽略——war 没有"应用主类参数"的概念，应用级配置由 webapp 自身处理。

## 引擎与依赖声明

launch spec 用一个 `[engine]` 段描述"如何用引擎跑这个 war"：

```ini
[app]
entry = gav://org.example:webapp:0.0.1:war

[engine]
init = engine-creator tomcat  # 必填：引擎 init 命令（路径，或“程序 + 参数”）
org.beangle.bas:beangle-bas-engine:0.13.17
org.apache.tomcat.embed:tomcat-embed-core:11.0.21
org.apache.tomcat.embed:tomcat-embed-websocket:11.0.21

[args]
--port=8080
--path=/
```

- `init`（必填）：引擎 init 命令（最简是路径，也可带参数），不是 java 类；由它自己决定
  调用哪个容器入口、怎么拼 classpath。jstart 不提供别名/FQCN 映射。
- `[engine]` 其余行（可选）：引擎 jar 清单，每行与 `[libs]` 完全同语法（gav/本地文件/
  远程 url），原样解析、**没有占位符**。jstart 不内置任何依赖行——锁版本、升级、换镜像、
  引用本地 jar、切容器都只改这个文件，容器 jar 也由用户自己写全。
- `[engine]` 与 `[libs]` 相互独立：`[libs]` 是应用自身依赖（追加/覆盖在 war 内置清单
  之上），`[engine]` 是引擎启动器依赖，两者都按需拼进最终 classpath。
- `[app] engine` 已移除：写了会被告警忽略；引擎入口一律用 `[engine] init`。

### 为什么没有内置目录

jstart 不在代码里内置 tomcat/undertow 的 jar 清单，也不内置入口类映射：那会明显偏向
某个特定引擎，也让 jstart 发版与容器版本绑定。改为**用户显式声明**后，jstart 保持引擎
中立，任何 servlet 容器只要提供一个 init 命令并声明依赖即可运行。

代价是每个 war spec 都要写一段 `[engine]` 与一个 init 命令；可以把它放进模板/生成脚本，
或用一个共用的片段维护。若只想换容器版本，改 `[engine]` 里的版本号即可：

```ini
[engine]
init = engine-creator tomcat
org.beangle.bas:beangle-bas-engine:0.13.17
org.apache.tomcat.embed:tomcat-embed-core:11.0.24
org.apache.tomcat.embed:tomcat-embed-websocket:11.0.24
```

### 定制场景示例

1. **切换到 undertow**：init 换成 `engine-creator undertow`，并把引擎依赖换成
   undertow 的伴随 jar（行数不足可能缺容器类，需自行写全）：

```ini
[app]
entry = /path/app.war

[engine]
init = engine-creator undertow
org.beangle.bas:beangle-bas-engine:0.13.17
io.undertow:undertow-core:2.4.4.Final
io.undertow.ee:undertow-servlet:2.0.2.Final
io.undertow.ee:undertow-websockets:2.0.2.Final
org.jboss.logging:jboss-logging:3.6.3.Final
org.jboss.threads:jboss-threads:3.9.2
org.jboss.xnio:xnio-api:3.8.16.Final
org.jboss.xnio:xnio-nio:3.8.16.Final
jakarta.annotation:jakarta.annotation-api:2.1.1
jakarta.servlet:jakarta.servlet-api:6.1.0
jakarta.websocket:jakarta.websocket-api:2.2.0
jakarta.websocket:jakarta.websocket-client-api:2.2.0
org.wildfly.client:wildfly-client-config:1.0.1.Final
org.wildfly.common:wildfly-common:2.0.1
io.smallrye.common:smallrye-common-annotation:2.14.0
# ...其余 smallrye-common-*（constraint/cpu/expression/function/net/os/ref）同版本
```

2. **私有镜像或本地 jar**：gav 行配合 `run --remote=<内部源>`；或把引擎 jar 直接
   写成本地文件 / 远程 url 行：

```ini
[engine]
init = engine-creator tomcat
/opt/mirror/tomcat-embed-core-11.0.21.jar       # 本地引擎 jar（支持 ~ 与 ${VAR}）
https://repo.example.com/bas/beangle-bas-engine.jar
```

3. **引擎 JVM 参数**：与 jar 目标一致写 `[runtime]`；引擎自身参数
   （`--port=`/`--path=`）写 `[args]` 或命令行透传（base 用 `[app] base`/`--base=`，
   不要写进 `[args]`）：

```ini
[runtime]
-Xmx1g

[args]
--port=8080
--path=/
```

4. **检查装配**：`jstart run --print app.jstart` 打印将执行的启动命令（`--base` 下已有
   上次运行留下的 `engine-entry.argv` 时，打印其中保存的最终命令，否则打印 init 命令的
   准备命令；`--print` 不执行准备，也不要求程序已在 `PATH` 上），用于定制前后对照。

### classpath 顺序

```text
CLASSPATH_EXTRA → WEB-INF/classes → WEB-INF/lib/*.jar（排序） → 应用依赖 → 引擎依赖
```

引擎依赖以 g:a:v 与应用依赖去重（不重复追加）。解析/下载/校验与普通依赖完全一致
（curl 并行、`.sha1`、SNAPSHOT 快照库），且仍遵守"不解析传递依赖"的项目约束——
引擎 jar 是用户在 `[engine]` 里**显式写出的清单**。

## 与其它命令的关系

- `resolve <war>`：只解析并准备 war 内置依赖，打印 war 落盘路径，**不含**引擎；
- `classpath`/`info` 对 war 文件不展开、不涉及引擎（`info` 只额外给出 `engine init:`）；
  查看将执行的完整命令请用 `run --print`；
- `run --print <spec>`（entry 为 war）：照常下载引擎依赖；**不执行** init 命令的准备
  （准备有副作用），若 `--base` 下已有 `engine-entry.argv` 则打印其中的最终命令，否则
  打印 init 命令的准备命令（逐参数引号），不 exec；
- `repo <war>` / `repo <spec>`：只整合**应用**依赖（war 内置清单或 spec `[libs]`），
  不读取 `[engine]` 段。离线机器需要引擎 jar 时，先在联网机上
  `jstart run --print <spec>`（会下载应用 + 引擎依赖到 `--local` 仓库），再把该仓库
  目录拷到离线机（见 [offline.md](offline.md)）。

## 验证

用真实 beangle 组件做端到端运行验证（tomcat 与 undertow 均已通过）：默认 init 命令是
本仓库自带的 `test/engine-init-stub.sh`（一个最小的 creator，演示 [engine.md](engine.md)
的协议），要验证外部引擎工具时用 `--init='<命令>'` 覆盖：

```bash
bash test/war-run-test.sh                            # tomcat
bash test/war-run-test.sh --engine=undertow          # undertow
bash test/war-run-test.sh --local=/opt/repo --port=18080 --path=/ --engine=tomcat
bash test/war-run-test.sh --init='/opt/engine/bin/tomcat-init'
```

脚本启动 `org.beangle.otk:beangle-otk-ws:war:0.0.29`：解析并下载（首次约 100MB），
`init` 命令准备 docBase（`<base>/webapps/ROOT`）并 exec 容器，
等待 HTTP 响应后检查 `Tomcat started`/`Undertow started` 与应用启动日志，最后优雅关闭
并确认引擎清理 docBase。也可以手工跑：

```ini
[app]
entry = org.beangle.otk:beangle-otk-ws:war:0.0.29

[engine]
init = engine-creator tomcat
org.beangle.bas:beangle-bas-engine:0.13.17
org.apache.tomcat.embed:tomcat-embed-core:11.0.21
org.apache.tomcat.embed:tomcat-embed-websocket:11.0.21

[args]
--path=/
```

```bash
jstart run otk.jstart --port=8080
```

> init 命令消费 jstart 的协议参数并写出容器启动命令。用真实组件跑本测试前，本地仓库需
> 有该版本的 bas 引擎 jar（或让 jstart 按 `[engine]` 行联网下载）。

## 限制

- 解压由引擎负责（zip-slip 防护在引擎侧）；超大 war 的峰值内存视引擎的 zip 实现而定；
- `--entry` 必须是存在的 war 文件或 webapp 目录（目录直接用，不解压，方便本地目录项目）；
- `init` 命令**不经过 shell**：只做分词与 `~`/`${VAR}` 展开，没有管道/重定向/通配符，
  需要时写 `sh -c '...'`；可执行程序必须是真程序（脚本靠 `#!`），Windows 下没有 `#!`
  解释器约定，脚本支持受限；
- "可执行 war"（自带 Main-Class 的 Spring Boot 式 fat war）不支持，war 一律按
  引擎模式运行；
- init 命令与 docBase 公式随 beangle/bas 版本演进；容器行为（参数消费、docBase 删除
  时机）以 bas 源码语义为准。
