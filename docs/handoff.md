# jstart ↔ engine init 交接协议

本文只讲一件事：jstart 把 `[engine] init` 拉起来之后，两边怎么交换最终启动命令。
整体 run 流程见 [engine.md](engine.md)，spec 格式见 [launch-spec.md](launch-spec.md)。

## 1. 谁写 `jstart.argv`

所有模式都会在组件目录留下 `jstart.argv`（**最终启动命令，NUL 分隔 argv**）：

| 模式 | 谁写 | 何时写 |
|---|---|---|
| jar（`[app] main`） | jstart | exec 前 |
| native（`[app] exec`） | jstart | exec 前 |
| engine（war / 容器） | `[engine] init` 脚本 | 脚本退出前 |

engine 模式下 jstart 不会自己拼容器命令，它把路径通过 `--entry-out=<base>/jstart.argv`
交给 init；init 写完后退出，jstart 再读。

```
jstart run
  → 运行 <init> ... --entry-out=<base>/jstart.argv
  → init 写 NUL 分隔的 argv，退出 0
  → jstart readText / split('\0') → execvp
```

## 2. NUL 分隔格式

`jstart.argv` 的内容是：

```text
java\0-Xmx1g\0-cp\0<very long classpath>\0Main\0--port=8080\0
```

- 每个参数之间是 **NUL**（`\0`），不是空格/换行
- 末尾通常有一个 NUL，jstart 会去掉结尾空项；中间空参数保留
- 参数内部可以包含空格、引号、换行，不影响边界
- **文件名不是契约**：init 必须使用 `--entry-out` 给的路径，不能硬编码 `jstart.argv`

查看方式：

```bash
tr '\0' '\n' < /var/lib/bas/servers/openurp.base/jstart.argv
```

## 3. `jstart.args`：长命令

命令总长超过约 4 KiB 时，argv 会折成 Java 的 `@argfile`：

- 文件名：`jstart.args`（不再是 `engine-entry.args`）
- 内容：java 参数文件，一行一个参数，必要时加双引号/转义
- `jstart.argv` 只保留：

```text
java\0@/abs/path/to/jstart.args\0
```

- `jstart.args` **不能删**：Java 启动时还要读；下次启动会覆盖/清理
- **它不是 classpath 文件**：里面是完整 argv（JVM 参数 + `-cp` + classpath + 主类 + 参数）

## 4. engine 模式传给 init 的参数

```
[engine] init = <命令>
```

jstart 执行：

```bash
<命令> --base=<组件目录> \
       --entry=<war|目录> \
       --engine-classpath-file=<base>/engine-deps.classpath \
       --app-classpath-file=<base>/engine-app.classpath \
       --local-repo=<本地仓库> \
       --entry-out=<base>/jstart.argv \
       --app-jvm-arg=<JVM 参数>... \
       [--port=... --path=... 等透传参数]
```

- `--entry` 只用于单 webapp；多 webapp 时 jstart 另写 `<base>/engine-subapps.jstart`
- `--app-jvm-arg` 来自 spec 的 `[runtime]`（含 `<server-options>`）
- 两个 classpath 文件只在 init 期间使用，init 成功后 jstart 删除
- init 的 stdout 被 jstart 捕获（`--verbose` 回显），stderr 透传
- init 退出码非 0 → 启动失败；没写 `jstart.argv` 或 argv 为空 → 启动失败

## 5. 生命周期

- `jstart.argv`、`jstart.args` 在 exec 后**保留**，作为最后一次启动的记录
- 下次 `run` 会先清掉旧 `jstart.argv`，再让 init 重写
- `engine-deps.classpath`、`engine-app.classpath`、`engine-subapps.jstart` 在 init 成功后删除
- 不提供 `run --print`：要看最终命令，直接读 `jstart.argv`（需要展开时用 `tr`）

## 6. 预取依赖

`jstart resolve <spec>` 现在会把 `[engine]` 段里的引擎 jar 也取回，可用于离线预取；
它不会运行 init，也不会生成 `jstart.argv`。最终命令只能在 `run` 时得到。
