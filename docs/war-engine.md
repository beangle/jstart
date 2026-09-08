# War 内置引擎运行

war 没有 `Main-Class`，不能像 jar 那样 exec 应用主类。jstart 采用与 beangle/boot
`sas.sh` 相同的模型：把 war **爆炸**到引擎约定的目录，拼好 classpath 后 exec
**内嵌 servlet 引擎**的 Bootstrap 类——最终进程仍是 `java`，无父子等待。

```text
java <runtime-options> -cp <WEB-INF/classes + WEB-INF/lib/*.jar + 应用依赖 + 引擎依赖>
     org.beangle.sas.engine.tomcat.Bootstrap --base=<base> [args...]
```

## 何时启用

`run` 的目标解析为 war 落盘文件时启用（本地 `app.war`、`g:a:v`/`gav://`（配合
`--preferwar`）、`http(s)://` url 下载后 `.war`）；launch spec 的 `entry` 为 war 时
同样启用。**war 可以不写 launch spec 直接运行**：

```bash
jstart run /path/app.war --port=8080 --path=/
```

launch spec 只在需要"声明引擎选择 / 固定引擎依赖版本 / 其它启动参数"时使用
（见下）。

## 爆炸布局（与 sas 引擎约定一致）

引擎（beangle/sas `Server.Config.guessDocBase`）按固定公式推导 docBase，jstart 在
exec 前把 war 爆炸到同一位置：

| 参数 | 布局 |
|------|------|
| `--path` 缺省或 `/` | `<base>/webapps/ROOT` |
| `--path=/a/b` | `<base>/webapps/a#b`（先归一化：去尾 `/`、折叠 `//`） |

- `base` 默认 `${TMPDIR:-/tmp}/jstart-sas`（对齐 sas.sh 的 `/tmp/sas` 定位），用
  `--base=<dir>` 覆盖；
- 每次运行前**重建**爆炸目录（先删后炸）；引擎关闭（shutdown hook）时会自行删除
  docBase，被 `kill -9` 留下的残骸由下一次运行清理；
- 同一 `base` 上并发运行相同 context path 会冲突（与 sas.sh 相同），需要各自
  `--base=`；
- 无 `WEB-INF/classes` 的极简 war 会补一个空目录（引擎启动时要探测 classpath 上的
  目录资源，全是 jar 时 `getResource("")` 为 null）。

## 参数语义（例外解析）

引擎模式下 jstart 只**读取**两个参数用于布置爆炸位置，其余一律原样透传：

- `--path=`：决定 contextPath 与爆炸目录，之后仍原样转发给引擎；
- `--base=`：决定 base（命令行与 launch spec `[args]` 均参与扫描，最后一次出现
  生效，与引擎 `CmdOptions` 一致）；消费后不再重复转发，统一以
  `--base=<最终值>` 放在引擎参数首位；
- `--port=8080` 等不读取、原样透传：端口由引擎消费（被占用时自动探测 8080 起的
  空闲端口或报错）；
- 其它参数照常透传。注意 **sas 引擎本身只消费 `--path/--port/--dev/--base`**，
  其余打印 `ignore param` 后忽略——war 没有"应用主类参数"的概念，应用级配置由
  webapp 自身处理。

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

- `[app] engine`：引擎名。已知映射
  `org.beangle.sas.engine.<name>.Bootstrap`（tomcat/undertow）；war 缺省 `tomcat`，
  未知引擎名在 `run` 时报错。tomcat 可带版本后缀（如 `tomcat-11.0.24`）：不带
  `[engine]` 段时，内置目录里两个 `tomcat-embed-*` jar 自动用该版本
  （`beangle-sas-engine` 仍用内置默认版本）；不带后缀用内置默认版本。
- `[engine]` 段：引擎 jar 清单，每行与 `[deps]` 完全同语法（gav/本地文件/远程 url）。
  **段存在即为权威，jstart 不内置依赖行**——引擎版本随 spec 走，升级/换源/改
  undertow 只改文件，不重新发版。行内可用版本占位符 `{tomcat.version}`（`engine =
  tomcat-<版本>` 时用该版本，否则内置默认）与 `{sas.version}`（内置默认），由
  jstart 展开后再装配。
- `[engine]` 与 `[deps]` 相互独立：`[deps]` 是应用自身依赖（存在时替换 war 内置
  清单），`[engine]` 是引擎启动器依赖，两者都进 classpath。
- jar / 非 java 运行时目标**不要求** engine 声明；spec 里写了 `[app] engine` 或
  `[engine]` 段而 entry 不是 war 时，告警并忽略。

### 没有 launch spec / 没有 [engine] 段时

`jstart run app.war` 或 spec 未写 `[engine]` 时回退**内置默认目录**（版本固定，
等价 sas.sh 两个分支的 `download` 行）。

tomcat（3 个 jar，内嵌 jar 自带 jakarta.servlet API，可自包含）：

| 构件 | 版本 |
|------|------|
| `org.beangle.sas:beangle-sas-engine` | 0.13.10 |
| `org.apache.tomcat.embed:tomcat-embed-core` | 11.0.21 |
| `org.apache.tomcat.embed:tomcat-embed-websocket` | 11.0.21 |

undertow（14 个 jar：sas 引擎 + undertow/xnio/wildfly/smallrye）：

| 构件 | 版本 |
|------|------|
| `org.beangle.sas:beangle-sas-engine` | 0.13.10 |
| `io.undertow:undertow-core`、`undertow-servlet` | 2.3.24.Final |
| `org.jboss.logging:jboss-logging` | 3.6.1.Final |
| `org.jboss.threads:jboss-threads` | 3.7.0.Final |
| `org.jboss.xnio:xnio-api`、`xnio-nio` | 3.8.16.Final |
| `jakarta.annotation:jakarta.annotation-api` | 2.1.1 |
| `org.wildfly.client:wildfly-client-config` | 1.0.1.Final |
| `org.wildfly.common:wildfly-common` | 1.5.4.Final |
| `io.smallrye.common:smallrye-common-annotation`/`-constraint`/`-cpu`/`-function` | 2.6.0 |

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
org.beangle.sas:beangle-sas-engine:0.13.10
io.undertow:undertow-core:2.3.24.Final
io.undertow:undertow-servlet:2.3.24.Final
# ...其余 xnio/wildfly/smallrye 行见上方内置目录表
```

3. **私有镜像或本地 jar**：gav 行配合 `run --remote=<内部源>`；或把引擎 jar 直接
   写成本地文件 / 远程 url 行：

```ini
[engine]
/opt/mirror/tomcat-embed-core-11.0.21.jar       # 本地引擎 jar（支持 ~ 与 ${VAR}）
https://repo.example.com/sas/beangle-sas-engine.jar
```

4. **引擎 JVM 参数**：与 jar 目标一致写 `[runtime]`；引擎自身参数
   （`--port=`/`--path=`/`--base=`）写 `[args]` 或命令行透传：

```ini
[runtime]
-Xmx1g

[args]
--port=8080
--path=/
```

5. **检查装配**：`jstart run --print app.jstart` 打印将执行的
   `java ... Bootstrap --base=...` 命令行（引擎 jar、透传参数一目了然），用于定制
   前后对照。

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
- `run --print <war>`：照常下载引擎依赖并爆炸，打印
  `java ... Bootstrap --base=...`（逐参数引号），不 exec；
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

脚本启动 `org.beangle.otk:beangle-otk-ws:war:0.0.29`：解析并下载（首次约 100MB）、
爆炸到 `<base>/webapps/ROOT`、exec 所选引擎的 Bootstrap，等待 HTTP 响应后检查
`Tomcat started`/`Undertow started` 与应用启动日志，最后优雅关闭并确认引擎清理
docBase。也可以手工跑（war 缺省 tomcat；undertow 需 launch spec）：

```bash
jstart run org.beangle.otk:beangle-otk-ws:war:0.0.29 --port=8080 --path=/
jstart run app.jstart --port=8080      # [app] engine = undertow
```

## 限制

- 解压走内存 zip 读取（std.zip），超大 war 有内存峰值；路径穿越/绝对路径条目在
  爆炸时被跳过（zip-slip 防护）；
- 只支持 war **文件**目标；已解压的 war 目录作为 run 目标暂不走引擎流程；
- "可执行 war"（自带 Main-Class 的 Spring Boot 式 fat war）不支持，war 一律按
  引擎模式运行；
- 引擎主类与布局公式与 beangle/sas 当前版本绑定；引擎行为（参数消费、docBase
  删除时机）随 sas 版本演进，本文件以其源码语义为准。
