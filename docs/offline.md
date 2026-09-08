# 离线部署与无外网启动

jstart 的下载只发生在"本地仓库缺构件"时。因此可以在一台能联网的机器上把依赖集齐到
指定仓库目录，再连同应用一起拷到无外网机器上启动。

## 场景一：联网机器上准备离线仓库

```bash
# 1. 联网机器上把 release 依赖集齐到 ~/.m2/repository
#    （SNAPSHOT 时间戳构件在独立的 ~/.m2/snapshots，不在此目录，见下方注意事项）
jstart --quiet resolve /path/to/app.jar

# 2. 整合到独立离线目录（默认源为 ~/.m2/repository）
jstart --quiet repo /path/to/app.jar --local=/opt/offline-repo
```

`repo` 会复制 jar 与 `.sha1`。之后把以下内容一起拷到目标机：

- `jstart` 可执行文件（或其 deb/rpm 安装包）
- `/opt/offline-repo/`（或打成 tar 带走）
- 应用 `app.jar`

校验离线目录：

```bash
jstart --local=/opt/offline-repo --quiet resolve /path/to/app.jar && echo ready
```

退出码 0 表示依赖齐备（缺件时退出码为 1 并打印 `Missing: ...`）。

## 场景二：无外网机器上启动

```bash
# 显式指向离线仓库，并阻止远程访问
jstart --local=/opt/offline-repo --quiet run /path/to/app.jar --port=8080

# 或分步做脚本解耦
info=$(jstart --local=/opt/offline-repo --quiet classpath /path/to/app.jar)
main=${info%@*}; cp=${info#*@}
exec java -cp "$cp" "$main" --port=8080
```

注意事项：

- 若 jar 在离线目录中已存在且 `.sha1` 齐全、校验通过，jstart **不会发起任何网络请求**
  （连远程探测都没有——下载实现只在实际缺件时调用 curl）。
- 本地文件行（`lib/extra.jar` 等）不会被 `repo` 复制，请随应用一起部署；其路径相对
  启动时的工作目录。
- 拷贝时请连同 `.sha1` 一起复制：一旦离线机器上 jar 与 `.sha1` 不一致，jstart 会删除
  构件并尝试重下（离线时即失败并报 Missing）。
- **快照库与 repository 不混合**：`repo` 整合只覆盖本地仓库（release 布局）；SNAPSHOT
  时间戳构件平时在独立的 `~/.m2/snapshots`，不会被 `repo` 复制。若应用依赖 SNAPSHOT
  且目标机无外网，请把联网机上快照库对应时间戳文件（默认
  `~/.m2/snapshots/g/a/1.0-SNAPSHOT/a-1.0-<yyyyMMdd.HHmmss>-<build>.jar`）拷贝到目标机
  相同位置；使用 `--local=/opt/offline-repo` 时，放到该目录下对应的快照路径即可
  （显式 `--local` 后快照文件定位在同一 base，不再另设 `~/.m2/snapshots`）。

## 常见流程示例

```bash
# 交付物打包
tar czf offline-bundle.tgz jstart app.jar offline-repo/

# 目标机
./jstart --local=./offline-repo run app.jar --port=8080
```

## war 目标与引擎依赖的离线

`run <war>` 除了应用自身依赖，还需要**引擎 jar**（tomcat/undertow 内置默认目录或
spec `[engine]` 罗列），两者都要在联网机上先集齐：

```bash
# 联网机：解析并下载（run --print 也会下载后只打印命令，不启动）
jstart --quiet run --print app.jstart --local=/opt/offline-repo

# 校验：退出码 0 表示含引擎依赖在内全部齐备
jstart --local=/opt/offline-repo --quiet resolve app.war && echo ready
```

注意：

- `repo` 子命令**只整合应用依赖**（war 内置清单或 spec `[deps]`），不读取 `[engine]`
  段，也不会复制引擎 jar；引擎依赖请用上面的 `run --print`（或 `resolve` 后手工
  `repo` 引擎 spec 的 `[deps]`）预下载进离线仓库；
- 引擎版本可用 `[app] engine = tomcat-11.0.24` 或 `[engine]` 行
  `{tomcat.version}`/`{sas.version}` 占位符指定（见 [war-engine.md](war-engine.md)），
  解析出的具体版本与其它引擎 jar 一样随 `run --print` 预下载进离线仓库；
- 引擎 jar 是 release 构件，落在普通本地仓库布局，随仓库一起拷贝即可，无需处理
  快照库。

无外网机请使用**本地** `.jstart`：远程 spec 需要联网下载（`run` 才支持；
`repo` 只接受本地 target，远程 spec 在进入流程前即被拒绝）。

## 多应用共享离线仓库

离线仓库目录结构与 maven 本地仓库一致，可同时容纳多个应用的依赖：

```bash
jstart --quiet repo /path/app1.jar --local=/opt/offline-repo
jstart --quiet repo /path/app2.war --local=/opt/offline-repo
```

相同构件只在第一次复制，后续命令跳过（本地已存在判定）。
