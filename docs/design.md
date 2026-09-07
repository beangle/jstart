# 设计思路

jstart 借鉴 beangle/boot 的思路，用 D 语言实现为**单原生二进制**：不需要 JVM 参与解析阶段，
最终以 exec 方式把控制权交给应用进程。

## 与 beangle/boot 的对应关系

原 Scala 项目把"解析"与"执行"拆成两步，由 shell 串联：

```text
resolve.sh（AppResolver → 下载依赖 → 应用路径）
    ↓
launcher.Classpath（Main-Class@classpath）
    ↓
java -cp ... Main-Class args          # 由 launch.sh 直接执行
```

jstart 用四个子命令覆盖同一职责：

| jstart | 原 boot 组件 | 作用 |
|--------|--------------|------|
| `resolve` | `dependency.AppResolver` | 解析目标、下载缺失依赖、输出应用路径 |
| `classpath` | `launcher.Classpath` | 输出 `Main-Class@classpath` |
| `repo` | `launcher.Repo` | 离线仓库整合（复制缺失构件） |
| `run` | `resolve.sh` + `launch.sh` | 准备环境后 exec 成 java |

保留 `resolve`/`classpath` 是为了兼容 launch.sh 式的脚本解耦；`run` 则把两步合并进
单个进程。

## 为什么用 exec

beangle/boot 的做法是"解析进程退出，shell 再执行 java"，最终进程就是 java、没有多余
的父子等待关系。jstart 是单二进制，无法像 shell 那样先退出再执行，因此 `run` 在解析
完成后调用 `execvp` **用 java 替换自身进程**：

- 最终进程仍是 `java`（同一 PID），父进程就是启动 jstart 的 shell；
- 退出码、信号、stdin/stdout/stderr 行为与直接运行 java 完全一致；
- 解析器在 exec 后不再存活，不存在"jstart 挂着等 java"的问题。

Windows 没有等价的 `exec`，`run` 退化为 `spawnProcess + wait`（子进程方式），代码中
已用 `version (Windows)` 分支注明。

## 模块架构

```text
source/app.d                    命令入口与参数解析
source/jstart/archive.d         依赖模型：Artifact/LocalFile/RemoteFile、gav、Maven2 布局
source/jstart/repo.d            本地仓库 LocalRepo、远程仓库列表、sha1 工具
source/jstart/http.d            调用宿主 curl 下载（仿 micdn）
source/jstart/zipfile.d         jar/war 条目读取、Manifest Main-Class 解析
source/jstart/resolver.d        目标解析、依赖准备、CLASSPATH 装配
source/jstart/consolidate.d     repo 离线整合（复制 jar + .sha1）
source/jstart/launcher.d        exec java / 原生启动器
```

依赖关系：`app.d → resolver/consolidate/launcher → archive/repo/http/zipfile`。

## 依赖准备流程

1. **定位应用**（`fetchTarget`）：本地文件/目录直接使用；`g:a:v`/`gav://` 先按 gav
   下载主包；`http(s)` url 按主机路径缓存到本地仓库镜像目录。
2. **读取依赖描述**（`resolveDependencies`）：
   - jar：`META-INF/beangle/dependencies`
   - war：`WEB-INF/classes/META-INF/beangle/dependencies`（缺失时回退 jar 位置）
   - 解压目录：目录下对应 war 路径的文本文件
   - 普通文本文件：本身即依赖描述
3. **逐行解析**（`parseDependencyText`）：空行忽略、重复行去重，格式见
   [dependencies.md](dependencies.md)。
4. **下载校验**（`ensureArtifact`/`ensureRemoteFile`）：本地已有则用 `.sha1` 校验，
   缺失/损坏按远程顺序逐个下载；同远程再取 `.sha1` 复核，不匹配删除并尝试下一远程。
5. **装配**（`buildClasspath`）：应用 jar（或解压 war 的 `WEB-INF/classes`+`WEB-INF/lib`）
   在前，依赖在后，`CLASSPATH_EXTRA`/`classpath_extra` 前置。
6. **执行**（`run`）：读 Manifest `Main-Class`，exec 为
   `java [jvm opts] -cp <cp> <Main-Class> [args...]`。

## 仓库与校验策略

- 本地仓库默认 `~/.m2/repository`（`--local=` 覆盖，支持 `~` 展开）。
- 远程默认顺序：阿里云 public → 华为云 maven → Maven Central；`--remote=` 覆盖时
  Central 总会保留在末尾（对齐原版行为）。
- sha1 语义（对齐原版）：
  - 本地文件 + `.sha1` 齐全 → 校验，不匹配则删除重下；
  - 本地文件存在但 `.sha1` 缺失 → 尝试从远程补拉，拉不到则"verify aborted"接受；
  - 新下载成功后从同一远程补拉 `.sha1` 复核；远程无 `.sha1` 时接受；
  - SNAPSHOT 构件跳过校验（时间戳版本解析为路线图内容）。
- 下载统一走宿主 `curl` 命令：`--fail --silent --show-error -L`，先写同目录
  `.name.part` 临时文件再 rename，避免跨设备移动与半截文件。

## 约束与取舍

- **不解析传递依赖**：依赖描述文件是唯一来源，只逐行处理显式依赖（见流程第 3 步），
  不读 POM、不展开传递依赖；全部运行期依赖须由构建期插件写全，漏写以 Missing 失败。
- `run` 目前只支持带 `Main-Class` 的 jar；war 需要内嵌 servlet 引擎（对应 beangle sas），
  属于路线图。
- 下载为串行单连接，尚未实现 Range 多线程分段（路线图）。
- 原生可执行目标：`launcher.runNativeApp` 已预留同形 exec 入口，等后续接入。
