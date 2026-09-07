# Changelog

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
  失败回退单请求）；SNAPSHOT 时间戳构件进独立快照库（`~/.m2/snapshots`，不与
  repository 混合），本地最新时间戳命中即用
- **war 引擎运行**：`run` 对 war 目标爆炸到 `<base>/webapps/<ctx>` 后 exec 内嵌引擎
  Bootstrap（tomcat/undertow，均有内置默认依赖目录；launch spec 用 `[app] engine`
  选择、`[engine]` 段显式罗列引擎依赖以覆盖默认；`--path`/`--base` 例外解析；
  zip-slip 防护），见 docs/war-engine.md
- **工程**：纯 Phobos 零 dub 依赖；`scripts/build_common.sh` + `build_deb.sh` + `build_rpm.sh` 打包（产物 `target/`）；下载改用宿主 curl 后 release 二进制约 470KB
- **测试**：单元测试覆盖 gav/布局解析、sha1 校验、jar/war/目录/文本依赖文件解析、zip/Manifest 读取、爆炸解压、引擎布局与 repo 整合复制；`test/smoke.sh` 端到端验证 resolve/classpath/缓存命中/gav/run 参数转发/war 引擎 --print；`test/war-run-test.sh` 用真实组件 `org.beangle.otk:beangle-otk-ws:war:0.0.29` 验证 tomcat/undertow 引擎启动（可选，联网+大下载）

完整说明见 docs/release-v0.0.1.md
