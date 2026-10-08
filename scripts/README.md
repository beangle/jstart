# 构建与打包脚本

| 路径 | 用途 |
|------|------|
| `build_common.sh` | 打包共用：`dub clean`、清空 `target/`、`dub build --build=release-nobounds` |
| `build_deb.sh` | 构建 `.deb`（需 Debian 系或 `dpkg-deb`、`fakeroot`） |
| `build_rpm.sh` | 构建二进制 `.rpm`（需 `rpmbuild`、`fakeroot`，在 Fedora/RHEL 系运行） |

产物统一输出到 `target/`：

- `target/jstart`：release 二进制
- `target/jstart_<v>-<r>_amd64.deb`：Debian/Ubuntu 安装包
- `target/jstart-<v>-<r>.<arch>.rpm`：Fedora/RHEL 安装包

`<v>` 取自**最近的 git tag**（`v0.0.1` → `0.0.1`，见 `build_common.sh` 的
`jstart_package_version`）；`dub.json` 不再写 `version`。仓库里没有可达 tag（还没打 tag、
浅克隆或 `--no-tags` 克隆）时脚本报错退出，并把 git 的原话打出来，不拿分支名兜底出一个
合不成的版本号。RPM 的 `%changelog` 只收 `CHANGELOG.md` 里 `## v<版本>` 小节的条目，
`## Unreleased` 的预留内容不进包。

`.deb`/`.rpm` 仅安装 `/usr/bin/jstart`。jstart 定位为**命令**而非系统服务（区别于
micdn 的常驻服务打包：无 systemd 单元、无服务启停脚本、无默认配置、无独立用户），
运行时依赖宿主 `curl` 命令完成依赖下载。
