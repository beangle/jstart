# Changelog

## Unreleased

- **测试自带最小 creator**：war 端到端测试改用仓库内的 `test/engine-init-stub.sh` 作为
  `[engine] init` 命令（演示协议本身），不再假定某个外部引擎工具；要验证真实工具用
  `--init='<命令>'`。文档中的 init 示例统一改为中性的 `engine-creator`
- **`[engine] init` 支持命令行形式（不再只是单个脚本路径）**：取值按 shell 风格分词
  （空白分隔、单/双引号成组、`\` 转义，**不经过 shell**，无管道/重定向/通配符），再对
  每个 token 做 `~`/`${VAR}` 展开；程序按路径或 `PATH`（Windows 加 `PATHEXT`）解析成
  绝对路径，其余 token 作为程序自带参数保留，jstart 的协议参数追加在后。于是可以直接写
  `init = engine-creator tomcat-server`，无需再为每个引擎类型写 wrapper 脚本；`init = <路径>`
  的旧写法完全兼容
- **引擎入口改为 `[engine] init` 脚本（去掉 `[app] engine`）**：引擎入口不再是 java
  入口类/内置别名，而是 spec 里 `[engine] init = <脚本路径>` 声明的**脚本/可执行文件**
  （`~`/`${VAR}` 展开）。jstart 不做别名/FQCN 映射、不内置任何入口类；`[app] engine`
  已移除（写了会被告警忽略）。jstart 跑脚本准备容器环境，脚本把最终命令（NUL 分隔
  argv）写入 `--entry-out`，jstart 再 exec；参数含 `--base`/`--entry`/
  `--engine-classpath-file`/`--app-classpath-file`/`--local-repo`/`--entry-out`/
  `--app-jvm-arg` 与透传参数，协议见 docs/engine.md
- **移除内置引擎依赖目录**：不再内置 tomcat/undertow/Dist 的 jar 清单（保持引擎中立），
  引擎 + 容器 jar 由 `[engine]` 段除 `init` 外的行逐行罗列（原样解析、**不支持
  `{tomcat.version}`/`{bas.version}` 占位符**，依赖可留空）；缺 `[engine]` 或缺 `init`
  会报错并提示补全，多应用 spec 同样必须显式给 `init`。`[engine]` 行支持 gav/本地文件/
  远程 url，与 `[libs]` 同语法
- **启动模型 `LaunchType`（解析结果派生，不是 spec 键）**：jstart 解析 spec 后给每个目标
  派生 `app`/`engine` 两种类型——`app` 直接 exec 运行时（java 跑 jar/目录、native 可执行
  文件），`engine` 先跑 `[engine] init` 脚本再 exec 它写出的命令。判定**只看是否声明了
  引擎**（`[engine]` 段，或 `[subapp <id>]` 多 webapp），不再从 war 后缀反推；没有引擎
  声明的 war 会报错提示补声明。`info` 的 `type:` 改为输出该模型（`app`/`engine`，多应用
  为 `engine`）并给 `engine init:` 行，entry 的构件形态另用 `entry type:`
  （`jar`/`war`/`dir`/`native`/`file`）报告
- **war 引擎协议**：引擎与应用依赖的 classpath 都改由文件传递——jstart 写
  `<base>/engine-deps.classpath` 与 `<base>/engine-app.classpath`，init 脚本用
  `--engine-classpath-file=`/`--app-classpath-file=` 读取，避免命令行过长；脚本写出的
  最终命令过长时会折叠成 java 参数文件（`java @<file>`），由 java launcher 展开
- **多 webapp spec**：单个 spec 用若干 `[subapp <id>]` 段（`entry`/`path`，可选 `libs`）
  声明多个 webapp，由 `[engine] init` 脚本在同一 JVM 里各建一个 context。jstart 逐个取回
  webapp 并把各自依赖补齐到本地仓库（运行时由每个 Context 自己的 `DependencyClassLoader`
  按 war 清单解析，不合并进同一 JVM classpath）。交付文件走 **launch spec 片段**
  `<base>/engine-subapps.jstart`（一段一个 `[subapp <id>]`，含 entry/path/libs），脚本按
  `--base` 约定读取；`libs` 是 per-webapp 的扩展依赖（gav，追加在 war 清单之上，同名以
  libs 为准，对齐 bas `Webapp libs`），jstart 先取回本地仓库。`resolve`/`info` 按 webapp
  逐个输出，`classpath` 明确拒绝
- **spec 互斥校验**：`[app] main` 与 `[engine]` 段互斥，同时声明直接报错（jar 跑主类、
  引擎目标由 init 脚本启动，语义冲突）
- **`[deps]` 段改名 `[libs]`，语义改为追加/覆盖**：不再"存在即替换 entry 内置清单"，
  而是**追加在**内置清单之上。**覆盖规则**：按 `groupId:artifactId` 判同名（不看版本、
  打包/classifier），同名时取 `[libs]` 的那条、版本用 `[libs]` 的，内置同名项整条丢弃
  （不会两个版本并存，classpath 里 libs 在前）；与容器 `libs` 的合并规则一致，native 等
  无内置清单的 entry 下即为全部依赖。顶层 `[libs]` 与 `[subapp]` 段互斥；旧名 `[deps]`
  仍可用（告警提示改名，行为等同 `[libs]`）
- **实例目录**：`--base=<dir>` 换 base 根（默认 `/var/tmp/jstart`）；launch spec 可用
  `[app] base` 固定根、`[app] instance = <name>` 显式命名组件目录（`<根>/<name>`，不拼指纹）
- **去掉 pid 文件与 `stop`**：jstart 只负责"解析 + 准备 + exec"，不再写
  `<base>/app.pid`，`stop` 子命令与 `--timeout` / `--force` 一并移除；`run` 原有的
  "同一实例在运行就拒绝启动"随之消失。实例身份与停止交给调用方（pid 由上层工具自记）
- **`--main=<class>` 覆盖主类**：run/classpath/info 指定 java 主类，优先于
  `[app] main` 与 jar 内 `MANIFEST.MF` 的 `Main-Class`；只对 jar/gav-jar/解压目录生效，
  war/native 目标告警忽略（空值或明显不是类名时用法错误 exit 2）
- **输出节制**：默认只输出告警/错误与命令结果；`--verbose`/`-v` 追加解析、下载、
  init 脚本的 stdout 与将执行的启动命令等过程细节，`--quiet`/`-q` 在默认之上再关闭
  告警（两者同给以 `--quiet` 为准，错误仍由退出码体现）
- init 脚本的命令行附带 `--local-repo=<本地仓库>`（jstart 的 `--local`，默认
  `~/.m2/repository`），供脚本给容器注入 `-Dbas.repo=` 等属性

## v0.0.1 (2026-09-07)

首个版本：仿照 beangle/boot 思路、用 D 语言实现的轻量 jar/war booter，单二进制（约 470KB，无 JVM/运行时依赖）。

- **命令**：`resolve`（解析并下载依赖、输出应用路径）、`classpath`（输出 `Main-Class@classpath`）、`run`、`repo`（离线仓库整合）
- **启动**：`run` 解析并准备依赖环境后，通过 `exec` 将自身进程替换为 `java`——最终进程即 java，无 jstart 父子等待，退出码/信号/stdio 与直接运行 java 一致
- **解析**：支持 jar/war/解压目录/文本依赖文件/`g:a:v`/`gav://`/`http(s)://` 目标；读取 jar 内 `META-INF/beangle/dependencies`（war 为 `WEB-INF/classes/...`），依赖行格式与原版兼容（gav、4/5 段 packaging/classifier、本地文件、远程 url，支持 `~`/`${VAR}`/`file://`）
- **下载**：调用宿主 `curl` 命令（仿 micdn 实现，`--fail -L` 等参数），不再链接 libcurl；下载后自动拉取 `.sha1` 校验，损坏/不匹配构件删除重下；远程仓库默认阿里云 public → 华为云 maven → Maven Central，支持 `--remote=` 覆盖与 `--local=` 指定本地仓库
- **repo**：仿照 `org.beangle.boot.launcher.Repo`，把目标应用缺失的构件（jar + `.sha1`）从 `--source` 仓库复制到 `--local` 仓库，供无外网机器离线启动
- **启动说明文件（launch spec）**：`run`/`resolve`/`classpath`/`repo` 支持 `.launch`/`.jstart`
  目标，ini 式声明 `[app]`/`[runtime]`/`[args]`/`[deps]`（通用运行时命名，旧 `[jvm]`/
  `[app] java` 告警移除）；新增 `info` 子命令与 `run --print`（打印将执行的命令）
- **下载**：多依赖并行（`--jobs`，默认 10）与单文件 Range 分段并行（≥1MB 最多 4 段，
  失败回退单请求）；SNAPSHOT 别名按上游元数据解析最新时间戳构建（micdn 的 `latest`
  响应头，其次版本目录的 `maven-metadata.xml`），落到独立快照库（`~/.m2/snapshots`，
  不与 repository 混合）；本地已有同一构建即用，上游不可达时回退本地最新时间戳文件，
  上游没有这类元数据时按字面文件名处理
- **离线**：新增 `--offline`，只用本地仓库——不探测、不下载（SNAPSHOT 也不再查
  `latest`/`maven-metadata.xml`），缺件直接失败；内置默认镜像与 Central 兜底只由
  `buildRemotes` 决定，调用方只需透传自己的仓库列表
- **SNAPSHOT 上游与正式版分开**：`--remote` 的默认镜像与 Central 兜底只作用于正式版；
  开发版专用新的 `--snapshot-remote=`（可选；**不兜到 `--remote`**，
  `buildSnapshotRemotes` 不追加 Central、不给默认镜像）；没配快照上游时本地快照库命中
  即用（不发请求、不报错），只有本地缺失、需要拉取才报错，不再因为"没配快照上游"而回落
  到公共镜像
- **fetch/native 不做快照语义**：发行包侧（`fetch` 与 native tar.gz gav）不再对 `-SNAPSHOT`
  做 `latest` 头/`maven-metadata.xml` 探测（native 构建费时、包大、发布不频繁，开发版一般
  不上传），只当字面版本名走「本地命中 → 增量补丁 → 整包下载」；`--snapshot-remote` 仅作用
  于 maven 依赖解析
- **war 引擎运行**：war 只能从 launch spec 进入 `run`（`[app] entry` 为 war 文件/gav；
  裸 war 目标对 `run` 直接报错，`resolve`/`fetch`/`repo` 仍直接接受 war）。jstart 把
  war/已解压目录交给**引擎入口 main**（`org.beangle.bas.engine.<name>.EmbedCreator`，可用
  FQCN 覆盖）：入口 main 准备环境、把最终 argv 写入 `engine-entry.argv` 后退出，jstart
  再 exec；war 的解压与 docBase 布局归引擎（jstart 不再自己爆炸，跨仓库契约取消，见
  docs/engine.md）。`[app] engine` 选入口 main、`[engine]` 段显式罗列引擎依赖以覆盖
  内置默认（tomcat/undertow）；`--base` 例外解析，`--path`/`--port` 等原样透传
- **引擎内置目录（undertow）**：对齐 bas 0.13.17 的 Jakarta EE 10 拆分——
  `io.undertow.ee:undertow-servlet/-websockets`（不再用 `io.undertow:undertow-servlet`）、
  undertow-core 2.4.4/XNIO 3.8.16/jboss 3.6.3+3.9.2/wildfly 2.0.1，并补齐
  `jakarta.servlet-api`/`jakarta.websocket(-client)-api` 与 wildfly-common 需要的
  smallrye-common（含 net/os/ref）共 22 个 jar；此前的目录缺 servlet API，`engine = undertow`
  会在启动时 `NoClassDefFoundError`
- **工程**：纯 Phobos 零 dub 依赖；`scripts/build_common.sh` + `build_deb.sh` + `build_rpm.sh` 打包（产物 `target/`）；下载改用宿主 curl 后 release 二进制约 470KB
- **测试**：单元测试覆盖 CLI 选项解析、gav/布局解析、sha1 校验、jar/war/目录/文本依赖文件解析、zip/Manifest 读取、引擎选择与 argv 解析、repo 整合复制；`test/smoke.sh` 端到端验证 resolve/classpath/缓存命中/gav/run 参数转发、war `--print` 与"入口 main 写 argv → exec"（本地 FakeEngine，不联网）；`test/war-run-test.sh` 用真实组件 `org.beangle.otk:beangle-otk-ws:war:0.0.29` 验证 tomcat/undertow 引擎启动（可选，联网+大下载）

完整说明见 docs/release-v0.0.1.md
