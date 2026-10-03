# 引擎入口 main（war 运行）

war 没有 `Main-Class`，不能像 jar 那样 exec 应用主类；它必须交给一个 **servlet 容器
引擎**。jstart 的做法是把 war 交给一个**引擎入口 main**：入口 main 准备引擎环境后，
把**最终启动命令**写到一个文件，jstart 再 exec 那条命令。最终进程是容器（`java`），
没有 jstart 父子等待。

这么做是为了让 **docBase 布局与 war 解压只归属引擎一处**：jstart 不再镜像容器的
解压公式，也不再有"跨仓库契约"——容器怎么算 docBase、怎么解压、怎么写自己的配置，
都由引擎自己决定。

```text
# 阶段 1：jstart 运行引擎入口 main（准备环境，短进程）
java -cp <引擎 jar> <entryMain> --base=<base> --entry=<war|dir> \
     --app-classpath-file=<file> --entry-out=<file> [--app-jvm-arg=<opt>...] [args...]

# 阶段 2：入口 main 把最终命令（NUL 分隔 argv）写入 --entry-out
#          jstart 读取并 exec（进程变为容器）
java <jvm opts> -cp <引擎 jar + 应用依赖 + WEB-INF> <容器 Bootstrap> --base=... ...
```

应用依赖的 classpath 可能非常长，jstart 不把它放在命令行上，而是写入
`<base>/engine-app.classpath`，用 `--app-classpath-file=` 把**文件路径**交给入口 main
（入口 main 用 `EngineCreator.Options.appClasspath()` 读取）。同理，若入口 main 拼出的最终命令
过长（例如把应用依赖放进了 `-cp`），它会把参数写成一个 java **参数文件**，`--entry-out`
里只留 `java @<file>`，由 java launcher 展开，避免超出行参上限（E2BIG）。

## 入口协议

| 参数 | 必填 | 含义 |
|------|------|------|
| `--base=<dir>` | 是 | 组件 base（jstart 的 `--base`/`--instance`/`[app] base`）；pid 文件、`webapps/`、引擎目录都在其下 |
| `--entry=<path>` | 单应用是 | war 文件，或**已解压的 webapp 目录** |
| `--webapps-file=<file>` | 多应用是 | 多 webapp 计划文件（代替 `--entry`）；一行一个 webapp：`id \t entry \t path` |
| `--entry-out=<file>` | 是 | 最终 argv 的写出文件（NUL 分隔） |
| `--app-classpath-file=<file>` | 否 | 存放应用依赖 classpath 的文件（jstart 解析出的 gav/本地/远程 jar，`<base>/engine-app.classpath`）；文件可能为空 |
| `--app-jvm-arg=<opt>` | 否，可重复 | 最终命令的 JVM 参数（来自 `[runtime]` 与命令行 `-D`/`-X`） |
| 其它参数 | 否 | 原样转发：`--path=`/`--port=`/`--Dkey=value` 等由各自的引擎消费 |

- **单应用**用 `--entry=`（可带 `--path=`、`--app-classpath-file=`）；**多应用**用
  `--webapps-file=`（此时不再有 `--entry=`，每个 webapp 的路径在计划文件里）。
- 入口 main 以 **0** 退出表示成功（此时 `--entry-out` 必须存在且非空）；非 0 即失败，
  jstart 直接返回该退出码。
- `--entry-out` 内容：**每个 argv 用 NUL(`\0`) 分隔**，通常带结尾 NUL。jstart 去掉
  结尾空项后 exec；中间的空参数保留。若命令过长，内容可能是 `java @<base>/xxx.args`
  （java 参数文件，入口 main 写出），jstart 原样 exec，由 java launcher 展开。
- 入口 main 的 **stderr 透传**（日志/错误）；stdout 被 jstart 捕获（`--verbose` 时回显），
  以免污染 jstart 自己的输出。

### `--entry` 是文件还是目录

- **文件（war）**：引擎按自己的公式解压到 `docBase`（beangle/sas 的公式见下），
  解压必须带 **zip-slip 防护**（跳过解析到目标目录之外的条目）。
- **目录（已解压 webapp）**：引擎**直接**把该目录当 `docBase`，不复制、不解压——
  方便本地前端/后端项目以目录形式发布调试。

## 选择引擎

launch spec 用 `[app] engine` 指定入口 main：

```ini
[app]
engine = tomcat                                # 内置别名（war 缺省 tomcat）
engine = tomcat-11.0.24                        # 内置别名 + tomcat 版本后缀
engine = org.beangle.sas.engine.tomcat.ServerCreator  # 或直接给入口 main 的 FQCN
```

- **含 `.` 的值**一律当作入口 main 的 FQCN（因此 `tomcat-11.0.24` 里的 `.` 不会被误判：
  值以已知别名开头时先按别名解析）。
- 内置别名与入口 main：

  | 别名 | 入口 main | 说明 |
  |------|-----------|------|
  | `tomcat` | `org.beangle.sas.engine.tomcat.EmbedCreator` | 内嵌 tomcat（可加版本后缀） |
  | `undertow` | `org.beangle.sas.engine.undertow.EmbedCreator` | 内嵌 undertow |

- 内置别名有**内置默认依赖目录**（见下）；**FQCN 一般没有内置目录**，必须在 `[engine]`
  段里写出该入口 main 所在 gav 集合。**例外**：全量 tomcat 的
  `org.beangle.sas.engine.tomcat.ServerCreator` 也有内置目录（beangle-sas-engine + tomcat
  发行包 zip），可省略 `[engine]`。

## 多 webapp（Dist 模式）

约定：**单个应用比较自由**（内嵌别名 `tomcat`/`undertow`、或任意入口 main FQCN），
**同一个 JVM 跑多个 webapp 只走 Dist 模式**——内嵌引擎只跑一个 webapp，多 war 在内嵌
里不是最佳实践。多应用 spec 的内嵌别名/`*EmbedCreator` 会在校验阶段直接报错；`[app]
engine` 省略时缺省用 `org.beangle.sas.engine.tomcat.ServerCreator`。

多应用时 jstart 不再用 `--entry=`/`--path=`/`--app-classpath-file=`，而是把每个 webapp
的入口与上下文路径写进 `<base>/engine-webapps.tsv`：

```text
id \t entry \t path
```

- `id`：`[webapp <id>]` 段头 id（命名用；引擎可用来定位日志/配置）；
- `entry`：该 webapp 的本地落盘路径（jstart 已取回：war 文件或已解压目录）；
- `path`：spec 里写的上下文路径，引擎按自身公式归一化后建 `<Context>`。

入口 main 用 `--webapps-file=<file>` 读取，**为每一行建一个 Context**（docBase 公式
仍是 `<base>/webapps/<ctx>`，每个 webapp 各自独立），最后只写出一份最终 argv。

- **依赖隔离**：每个 webapp 的依赖由它自己 Context 的 `DependencyClassLoader` 按该 war
  的 `META-INF/beangle/dependencies` 解析；jstart 只负责把各 webapp 的依赖取到本地仓库
  并透传 `--Dsas.repo`。**不要**把多个应用的依赖合并进同一个 JVM classpath（会串味）。
- **共享生命周期**：一个 base 一份 pid/一套 `webapps/`，`run`/`stop` 一次管整组
  （`stop` 只需 base）。
- **单应用路径不变**：`--entry=` 协议与 `--app-classpath-file=` 保持原样，ServerCreator 的
  单 Context 行为向后兼容。

> 引擎侧需支持 `--webapps-file=`（多 `<Context>`）：本仓库负责生成计划文件并下发；
> 消费端在 beangle/sas 的 `ServerCreator`（多 context 部署）落地。

## 引擎依赖：`[engine]` 段

```ini
[engine]                       # 可选段：引擎依赖，每行与 [deps] 同语法
org.beangle.sas:beangle-sas-engine:{sas.version}
org.apache.tomcat.embed:tomcat-embed-core:{tomcat.version}
org.apache.tomcat.embed:tomcat-embed-websocket:{tomcat.version}
```

- **段存在即为权威**：jstart 不再叠加内置目录（锁版本、升级、换镜像、引用本地 jar
  都只改本文件）。
- 行内可用占位符：`{tomcat.version}`（`engine = tomcat-<版本>` 时用该版本，否则内置
  默认）、`{sas.version}`（beangle-sas-engine 内置默认版本）。
- 没有 `[engine]` 段时，用别名对应的**内置默认目录**（等价 beangle/boot `sas.sh` 的
  下载行；`engine = tomcat-<版本>` 会用该版本重钉两个 tomcat-embed jar）。
- 引擎 jar 的解析/下载/校验与普通依赖完全一致（curl、`.sha1`、SNAPSHOT 快照库），
  仍只认显式清单，**不解析传递依赖**。

`org.beangle.sas.engine.tomcat.ServerCreator` 是 **FQCN 形式的全量 tomcat**：它解压
`--dist=<tomcat.zip>`（或 classpath 上的第一个 `.zip`）到 `<base>/engines/`，精简发行包，
把 classpath 上的引擎 jar 复制进其 `lib/`，生成 `conf/catalina.properties`、`conf/web.xml`
与单应用的 `conf/server.xml`，最后输出标准 catalina 启动命令。它对应原 core 的
`TomcatMaker`，能力已一对一收敛过来（后续可删除 `TomcatMaker`）。

不写 `[engine]` 段时 ServerCreator 用内置目录：`org.beangle.sas:beangle-sas-engine`（内置
版本）加 `org.apache.tomcat:tomcat:zip:<内置 tomcat 版本>` 发行包——ServerCreator 从 classpath
上取这个 zip 解压，无需额外 `--dist=`（也可在 `[engine]` 段显式钉发行包版本/镜像）。

ServerCreator 额外识别的参数（都通过 `[args]`/命令行透传）：

| 参数 | 含义 |
|------|------|
| `--dist=<zip>` | tomcat 发行包；缺省取 classpath 上第一个 `.zip` |
| `--jsp=true\|false` | 是否启用 JSP（缺省 `false`）：写 `conf/web.xml` 时决定 JSP servlet，并决定是否保留/删除 jasper、ecj 等 jar |
| `--listener=<class[:k=v;k2=v2]>` | Server 级 `<Listener>`，可重复；缺省用 Jre/ThreadLocal 泄漏防护 |

发行包内不再需要 `beangle-sas-juli` 以外的 juli：若引擎 classpath 提供了
`org.apache.juli.logging.Log`（`beangle-sas-juli`），删除 `bin/tomcat-juli.jar` 并由
`lib/*.jar` 提供；否则保留它。应用依赖走最终 classpath，并注入 `-Dsas.home=<base>`。

## 参数语义

- `--path=`：上下文路径。**jstart 不读取**，原样交给入口 main；引擎用它决定
  `docBase`（见下）。缺省 `/`。
- `--port=`：端口，原样透传（内嵌引擎缺省 8080 起探测空闲端口；ServerCreator 缺省同样探测）。
- `--Dkey=value`：引擎属性（内嵌引擎由 `CmdOptions` 消费；ServerCreator 转成 `-Dkey=value`）。
- `--listener=`/`--jsp=`：ServerCreator 的 Server 级 Listener 与 JSP 开关（见上）。
- `-D`/`-X` 开头的**命令行参数**归 JVM，作为 `--app-jvm-arg` 交给入口 main；
  `[runtime]` 段同理。
- `[args]` 段与命令行其余参数按顺序透传。

## docBase 布局（归属引擎）

beangle/sas 引擎按 `--base` + `--path` 推导（`Server.Config` / `EngineCreator`）：

| `--path` | docBase |
|----------|---------|
| 缺省或 `/` | `<base>/webapps/ROOT` |
| `/a/b` | `<base>/webapps/a#b`（归一化：去尾 `/`、折叠 `//`，`/` 换 `#`） |

- 每次运行前**重建**解压目录；容器关闭（shutdown hook）时会自行删除 docBase，
  被 `kill -9` 留下的残骸由下一次运行清理。
- **FQCN 入口 main** 与引擎自带目录（如 ServerCreator 的 `<base>/engines/`）也放在
  `--base` 下，一个 base 一个实例。

## 最小示例

```ini
[app]
entry = /path/app.war          # 也可是 g:a:v:war / gav://...:war / 已解压目录
engine = tomcat                # 可选，war 缺省 tomcat

[args]
--port=8080
--path=/
```

```bash
jstart run app.jstart
jstart run --print app.jstart      # 只打印（见下）
jstart stop app.jstart --base=/path/app.jstart-xxxx
```

`run` 拒绝**裸 war** 目标（本地 `app.war`、`g:a:v`、`http(s)://` 都不行）：引擎、参数、
base 都需要显式声明，正是 launch spec 的职责。`resolve`/`fetch`/`repo` 不受此限制，
仍可直接接受 war。

## `--print`

`run --print <spec>` **不执行**准备过程，只打印阶段 1 的引擎入口命令（准备可能有副作用，
如解压）。若 `--base` 下已有上次运行留下的 `engine-entry.argv`，则打印其中的**最终命令**，
便于查看 prepare 之后的真实启动行。

## 与其它命令的关系

- `resolve <war>`：只解析并准备 war 内置依赖，打印 war 落盘路径，**不含**引擎；
- `classpath`/`info` 对 war 不展开、不涉及引擎；
- `repo <spec>`：只整合**应用**依赖，不读取 `[engine]` 段。离线机器需要引擎 jar 时，
  先在联网机上 `jstart run --print <spec>`（会下载应用 + 引擎依赖到 `--local` 仓库），
  再把仓库目录拷到离线机（见 [offline.md](offline.md)）。

## 限制

- 入口 main 是**两阶段**启动：阶段 1 是短命的准备进程；准备失败时 jstart 直接报错退出。
- 解压走引擎自己的 zip 实现（zip-slip 防护）；超大 war 视引擎实现而定。
- "可执行 war"（自带 Main-Class 的 Spring Boot 式 fat war）不支持，war 一律按引擎运行。
- 容器行为（参数消费、docBase 删除时机）随 beangle/sas 版本演进，以 sas 源码语义为准。
