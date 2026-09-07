# 离线部署与无外网启动

jstart 的下载只发生在"本地仓库缺构件"时。因此可以在一台能联网的机器上把依赖集齐到
指定仓库目录，再连同应用一起拷到无外网机器上启动。

## 场景一：联网机器上准备离线仓库

```bash
# 1. 先让应用的所有依赖进入 ~/.m2/repository
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

## 常见流程示例

```bash
# 交付物打包
tar czf offline-bundle.tgz jstart app.jar offline-repo/

# 目标机
./jstart --local=./offline-repo run app.jar --port=8080
```

## 多应用共享离线仓库

离线仓库目录结构与 maven 本地仓库一致，可同时容纳多个应用的依赖：

```bash
jstart --quiet repo /path/app1.jar --local=/opt/offline-repo
jstart --quiet repo /path/app2.war --local=/opt/offline-repo
```

相同构件只在第一次复制，后续命令跳过（本地已存在判定）。
