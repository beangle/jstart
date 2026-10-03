# War 内置引擎运行

war 没有 `Main-Class`，不能像 jar 那样 exec 应用主类；它必须交给一个 **servlet 容器
引擎**。jstart 的做法是把 war（文件或已解压目录）交给一个 **引擎入口 main**：入口 main
准备容器环境、写出**最终启动命令**后退出，jstart 再 exec 那条命令；最终进程是容器
（`java`），无父子等待。

```text
# 阶段 1：jstart 运行引擎入口 main（准备环境，短进程）
java -cp <引擎 jar> <entryMain> --base=<base> --entry=<war|dir> \
     --app-classpath-file=<file> --entry-out=<file> [--app-jvm-arg=...] [args...]

# 阶段 2：入口 main 把最终命令写入 --entry-out，jstart 读取并 exec（进程变为容器）
java <runtime-options> -cp <引擎 jar + 应用依赖 + WEB-INF/classes + WEB-INF/lib/*.jar>
     <容器 main> --base=<base> [args...]
```

**war 的解压与 docBase 布局由引擎负责**：jstart 不再自己爆炸 war，也不镜像容器的布局
公式，只把 `--base` / war 路径 / 透传参数交给入口 main。协议（argv 文件格式、`--entry`
语义、错误约定）见 [engine.md](engine.md)。

## 何时启用

`run` 的目标是 **launch spec**、且其 `entry` 解析为 war 落盘文件时启用。war **不能**
作为 `run` 的裸目标（本地 `app.war`、`g:a:v`/`gav://`、`http(s)://` url 都不行）：
引擎、参数、base 都需要显式声明，而这正是 launch spec 的职责；给裸 war 目标 `run`
会报错并提示写成 spec。最小的 war spec：

```ini
[app]
entry = /path/app.war        # 也可是 g:a:v:war 或 gav://...:war
engine = tomcat              # 可选，war 缺省 tomcat

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

引擎按 `--base` + `--path` 推导 docBase（beangle/sas `Server.Config`/`EngineCreator`），
并在准备阶段把 war 解压到那里；jstart 只传参数，**不感知解压公式**。公式与重建/清理
时机见 [engine.md](engine.md)：

| 参数 | 布局 |
|------|------|
| `--path` 缺省或 `/` | `<base>/webapps/ROOT` |
| `--path=/a/b` | `<base>/webapps/a#b`（先归一化：去尾 `/`、折叠 `//`） |

- `base` 就是组件的运行目录 `<base 根>/<组件键>`：根默认 `/var/tmp/jstart`，用
  `--base=<dir>` 换根、`--instance=<name>` / launch spec `[app] base` 命名；`<base>/app.pid`
  是实例的 pid 文件，`<base>/webapps/<ctx>` 是引擎解压出的 docBase（一个 base 一个
  实例，多副本各自指定；也可指回 `${TMPDIR:-/tmp}/jstart-sas` 这类 sas.sh 风格的位置）；
- 引擎每次准备时**重建** docBase（先删后解压）；容器关闭（shutdown hook）时会自行删除
  docBase，被 `kill -9` 留下的残骸由下一次运行清理；
- 同一 `base` 上运行相同 context path 会冲突（与 sas.sh 相同）：默认已按组件隔离，
  多副本请各自指定 `--base`/`--instance`；
- 无 `WEB-INF/classes` 的极简 war 会补一个空目录（引擎启动时要探测 classpath 上的
  目录资源，全是 jar 时 `getResource("")` 为 null）。

## 参数语义（例外解析）

引擎模式下 jstart 只**读取** `--base`（jstart 自己的 base 选项），其余一律原样透传：

- `--base=`：是 jstart 的 base 选项（`--base=` 或 launch spec `[app] base`，命令行优先），
  不再从 `[args]` 里读（`[args]` 里的 `--base=` 会被丢弃，避免与注入值冲突）；jstart
  统一以 `--base=<base>` 放在入口 main 参数首位；
- `--path=`：上下文路径，jstart **不读取**，原样交给入口 main，引擎据此推导 docBase；
  缺省 `/`；
- `-D`/`-X` 开头的命令行参数与 `[runtime]` 段归 JVM，作为 `--app-jvm-arg` 交给入口 main
  写进最终命令；
- `--port=8080` 等其余参数不读取、按序原样透传（端口由引擎消费，被占用时自动探测空闲
  端口或报错）。注意 **sas 引擎只消费 `--path/--port/--dev/--base`**，其余打印
  `ignore param` 后忽略——war 没有"应用主类参数"的概念，应用级配置由 webapp 自身处理。

## 引擎与依赖声明

launch spec 用两个字段描述"如何用引擎跑这个 war"：

```ini
[app]
entry = gav://org.example:webapp:0.0.1:war
engine = tomcat                  # 可选 tomcat|undertow；war 缺省 tomcat
                                 # tomcat 可带版本：tomcat-11.0.24

[engine]                         # 可选段：引擎依赖逐行罗列（同 [deps] 语法）
org.beangle.sas:beangle-sas-engine:0.13.10
org.apache.tomcat.embed:tomcat-embed-core:11.0.21
org.apache.tomcat.embed:tomcat-embed-websocket:11.0.21
                                 # 行内可用占位符：{tomcat.version}/{sas.version}

[args]
--port=8080
--path=/
```

- `[app] engine`：入口 main。含 `.` 的值当作入口 main 的 FQCN；否则是内置别名
  `tomcat`/`undertow`（**先判别名再判 `.`**，所以 `tomcat-11.0.24` 不会被误当 FQCN）。
  内置别名映射到 `org.beangle.sas.engine.<name>.EmbedCreator`；全量 tomcat 发行版是
  `org.beangle.sas.engine.tomcat.ServerCreator`（写 FQCN 选用）。war 缺省 `tomcat`，未知
  别名在 `run` 时报错；FQCN 一般没有内置目录、必须写 `[engine]` 段（例外：全量 tomcat
  的 `ServerCreator` 有内置目录）。tomcat 别名可带版本
  后缀（如 `tomcat-11.0.24`）：不带 `[engine]` 段时，内置目录里两个 `tomcat-embed-*`
  jar 自动用该版本（`beangle-sas-engine` 仍用内置默认版本）；不带后缀用内置默认版本。
- `[engine]` 段：引擎 jar 清单，每行与 `[deps]` 完全同语法（gav/本地文件/远程 url）。
  **段存在即为权威，jstart 不内置依赖行**——引擎版本随 spec 走，升级/换源/改
  undertow 只改文件，不重新发版。行内可用版本占位符 `{tomcat.version}`（`engine =
  tomcat-<版本>` 时用该版本，否则内置默认）与 `{sas.version}`（内置默认），由
  jstart 展开后再装配。
- `[engine]` 与 `[deps]` 相互独立：`[deps]` 是应用自身依赖（存在时替换 war 内置
  清单），`[engine]` 是引擎启动器依赖，两者都进 classpath。
- entry 是 **war 文件或目录**时都走引擎流程（目录直接用，不解压）；其它目标（jar/native）
  **不要求** engine 声明，spec 里写了 `[app] engine`/`[engine]` 段会告警并忽略。

### 没有 [engine] 段时：内置默认目录

spec 未写 `[engine]` 时回退**内置默认目录**（版本固定，等价 sas.sh 两个分支的
`download` 行）。

tomcat（3 个 jar，内嵌 jar 自带 jakarta.servlet API，可自包含）：

| 构件 | 版本 |
|------|------|
| `org.beangle.sas:beangle-sas-engine` | 0.13.17 |
| `org.apache.tomcat.embed:tomcat-embed-core` | 11.0.21 |
| `org.apache.tomcat.embed:tomcat-embed-websocket` | 11.0.21 |

undertow（22 个 jar：sas 引擎 + undertow(EE10)/servlet/websocket API/xnio/wildfly/smallrye）：

| 构件 | 版本 |
|------|------|
| `org.beangle.sas:beangle-sas-engine` | 0.13.17 |
| `io.undertow:undertow-core` | 2.4.4.Final |
| `io.undertow.ee:undertow-servlet`、`undertow-websockets` | 2.0.2.Final |
| `org.jboss.logging:jboss-logging` | 3.6.3.Final |
| `org.jboss.threads:jboss-threads` | 3.9.2 |
| `org.jboss.xnio:xnio-api`、`xnio-nio` | 3.8.16.Final |
| `jakarta.annotation:jakarta.annotation-api` | 2.1.1 |
| `jakarta.servlet:jakarta.servlet-api` | 6.1.0 |
| `jakarta.websocket:jakarta.websocket-api`、`jakarta.websocket-client-api` | 2.2.0 |
| `org.wildfly.client:wildfly-client-config` | 1.0.1.Final |
| `org.wildfly.common:wildfly-common` | 2.0.1 |
| `io.smallrye.common:smallrye-common-annotation`/`-constraint`/`-cpu`/`-expression`/`-function`/`-net`/`-os`/`-ref` | 2.14.0 |

内置目录的价值是**开箱即用**（与 sas.sh 一致），但版本随 jstart 发版固定；要锁
其它版本、换镜像或离线定制时用 `[engine]` 段显式罗列——段存在即为权威（见下节）。
只换 tomcat 版本（不动 sas 引擎、不换镜像）时不必写 `[engine]`：
`engine = tomcat-11.0.24` 即可让内置目录按该版本装配。版本后缀目前仅 tomcat 支持：
undertow 换版本请写 `[engine]` 段并同步其伴随 jar（xnio/wildfly/smallrye 等，见
示例 2）。

### 定制场景示例

引擎定制有两个入口：

- 仅换 tomcat 版本（不动其它行）：直接 `[app] engine = tomcat-<版本>`（见上节）；
- 固定 sas 引擎版本、换镜像、引用本地引擎 jar、切换/改 undertow 等：写 `[engine]`
  段逐行罗列——段存在即权威，优先级高于内置默认目录。

1. **换 tomcat 版本**：只改版本、其余行都不动时，直接给 `[app] engine` 带版本后缀，
   无 `[engine]` 段也能让内置目录按该版本装配（`beangle-sas-engine` 仍用内置默认）：

```ini
[app]
entry = /path/app.war
engine = tomcat-11.0.24        # tomcat-embed-core/-websocket 用 11.0.24
```

   要同时固定 sas 引擎或本地镜像等其它行，写 `[engine]` 段并用占位符跟随该版本
   （`{tomcat.version}` 按 `engine = tomcat-11.0.24` 展开为 11.0.24；不带版本写
   `engine = tomcat` 时展开为内置默认版本）：

```ini
[app]
entry = /path/app.war
engine = tomcat-11.0.24

[engine]
org.beangle.sas:beangle-sas-engine:{sas.version}
org.apache.tomcat.embed:tomcat-embed-core:{tomcat.version}
org.apache.tomcat.embed:tomcat-embed-websocket:{tomcat.version}
```

   完全锁死某个版本（不随 `[app] engine`/jstart 变化）时，把版本号直接写进行里即可。

2. **切换到 undertow**：`engine = undertow`。不写 `[engine]` 用内置默认目录；写了
   就完全按罗列行装配（行数不足可能缺容器类，需自行写全）：

```ini
[app]
entry = /path/app.war
engine = undertow

[engine]                     # 可选：覆盖 undertow 内置默认目录
org.beangle.sas:beangle-sas-engine:0.13.17
io.undertow:undertow-core:2.4.4.Final
io.undertow.ee:undertow-servlet:2.0.2.Final
# ...其余 servlet/websocket API、xnio/wildfly/smallrye 行见上方内置目录表
```

3. **私有镜像或本地 jar**：gav 行配合 `run --remote=<内部源>`；或把引擎 jar 直接
   写成本地文件 / 远程 url 行：

```ini
[engine]
/opt/mirror/tomcat-embed-core-11.0.21.jar       # 本地引擎 jar（支持 ~ 与 ${VAR}）
https://repo.example.com/sas/beangle-sas-engine.jar
```

4. **引擎 JVM 参数**：与 jar 目标一致写 `[runtime]`；引擎自身参数
   （`--port=`/`--path=`）写 `[args]` 或命令行透传（base 用 `[app] base`/`--base=`，
   不要写进 `[args]`）：

```ini
[runtime]
-Xmx1g

[args]
--port=8080
--path=/
```

5. **检查装配**：`jstart run --print app.jstart` 打印将执行的启动命令（`--base` 下已有
   上次运行留下的 `engine-entry.argv` 时，打印其中保存的最终命令，否则打印入口 main 的
   准备命令；`--print` 不执行准备），用于定制前后对照。

### classpath 顺序

```text
CLASSPATH_EXTRA → WEB-INF/classes → WEB-INF/lib/*.jar（排序） → 应用依赖 → 引擎依赖
```

引擎依赖以 g:a:v 与应用依赖去重（不重复追加）。解析/下载/校验与普通依赖完全一致
（curl 并行、`.sha1`、SNAPSHOT 快照库），且仍遵守"不解析传递依赖"的项目约束——
引擎 jar 是用户或内置目录里**显式写出的清单**。

## 与其它命令的关系

- `resolve <war>`：只解析并准备 war 内置依赖，打印 war 落盘路径，**不含**引擎；
- `classpath`/`info` 对 war 文件不展开、不涉及引擎；查看将执行的完整命令请用
  `run --print`；
- `run --print <spec>`（entry 为 war）：照常下载引擎依赖；**不执行**入口 main 的准备
  （准备有副作用），若 `--base` 下已有 `engine-entry.argv` 则打印其中的最终命令，否则
  打印入口 main 的准备命令（逐参数引号），不 exec；
- `repo <war>` / `repo <spec>`：只整合**应用**依赖（war 内置清单或 spec `[deps]`），
  不读取 `[engine]` 段。离线机器需要引擎 jar 时，先在联网机上
  `jstart run --print <spec>`（会下载应用 + 引擎依赖到 `--local` 仓库），再把该仓库
  目录拷到离线机（见 [offline.md](offline.md)）。

## 验证

用真实 beangle 组件做端到端运行验证（tomcat 与 undertow 均已通过）：

```bash
bash test/war-run-test.sh                            # tomcat（默认）
bash test/war-run-test.sh --engine=undertow          # undertow
bash test/war-run-test.sh --local=/opt/repo --port=18080 --path=/ --engine=tomcat
```

脚本启动 `org.beangle.otk:beangle-otk-ws:war:0.0.29`：解析并下载（首次约 100MB），交给
所选引擎的入口 main（`EmbedCreator`）准备 docBase（`<base>/webapps/ROOT`）并 exec 容器，
等待 HTTP 响应后检查 `Tomcat started`/`Undertow started` 与应用启动日志，最后优雅关闭
并确认引擎清理 docBase。也可以手工跑（写一个最小 war spec；undertow 把 engine 换成
`undertow`）：

```ini
[app]
entry = org.beangle.otk:beangle-otk-ws:war:0.0.29

[args]
--path=/
```

```bash
jstart run otk.jstart --port=8080
```

> 入口 main 自 `beangle-sas-engine:0.13.17` 起提供；用真实组件跑本测试前，本地仓库需有
> 该版本的 sas 引擎 jar（或先用内置默认目录联网下载）。

## 限制

- 解压由引擎负责（zip-slip 防护在引擎侧）；超大 war 的峰值内存视引擎的 zip 实现而定；
- `--entry` 必须是存在的 war 文件或 webapp 目录（目录直接用，不解压，方便本地目录项目）；
- "可执行 war"（自带 Main-Class 的 Spring Boot 式 fat war）不支持，war 一律按
  引擎模式运行；
- 入口 main 与 docBase 公式随 beangle/sas 版本演进；容器行为（参数消费、docBase 删除
  时机）以 sas 源码语义为准。
