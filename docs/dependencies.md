# 依赖描述文件

与 beangle/boot 完全兼容：应用（瘦 jar/war）内置一行一个外部依赖的文本文件，
jstart 据此下载、校验并装配 classpath。

> **项目约束：不做传递依赖解析。** 描述文件是依赖的**唯一来源**，jstart 只逐行
> 处理其中显式写出的依赖，不读取 Maven POM、不做传递依赖展开与版本仲裁。因此
> 应用的全部运行期依赖必须由构建期插件显式、完整写入；漏写依赖不推导，会在
> 准备阶段报 Missing。

## 存放位置

| 应用类型 | 路径 |
|----------|------|
| jar | `META-INF/beangle/dependencies` |
| war | `WEB-INF/classes/META-INF/beangle/dependencies` |
| 解压后的 war 目录 | `<dir>/WEB-INF/classes/META-INF/beangle/dependencies` |

war 在该路径缺失时，jstart 会回退尝试 jar 的 `META-INF/beangle/dependencies`
（兼容"按可执行 jar 打包的 war"）。jar 内没有依赖描述时按自包含 jar 处理
（仍可读 Manifest 直接启动）。

## 行格式

每行一个外部依赖，支持四类：

### 1. Maven gav

```text
com.zaxxer:HikariCP:7.0.2              # g:a:v，打包类型 jar
ch.qos.logback:logback-classic:1.5.20
```

### 2. 带打包类型/classifier 的 gav

```text
g:a:war:1.0                            # 4 段：第三段是打包类型（jar/war/pom/zip/...）
net.sf.json-lib:json-lib:jdk15:2.4     # 4 段：jdk15 不在打包类型集合 → 视为 classifier
g:a:jar:jdk15:2.4                      # 5 段：g:a:packaging:classifier:version
```

打包类型集合（第三段命中即为 packaging，否则当作 classifier）：
`jar war pom zip ear rar ejb ejb3 tar tar.gz`。

`g:a:v` 与 `g:a:p:v` 等均可用 `gav://` 前缀显式声明：

```text
gav://org.apache.commons:commons-lang3:3.18.0
```

### 3. 本地文件

```text
lib/extra.jar                          # 相对路径（相对当前工作目录，与原版一致）
/opt/share/extra.jar
file:///opt/share/extra.jar            # file:// 前缀会被去掉
~/lib/extra.jar                        # 展开为用户主目录
${LIB_DIR}/extra.jar                   # ${VAR} 展开环境变量，未定义时保留变量名
```

### 4. 远程文件

```text
https://host/path/lib-1.0.jar
```

下载后按主机路径缓存到本地仓库镜像目录，例如
`<local>/host/path/lib-1.0.jar`。

解析规则小结（与 Scala 版 `Archive.apply` 对齐）：

- 以 `http://`/`https://` 开头 → 远程文件；
- 以 `gav://` 开头 → 去掉前缀后按 gav 解析；
- 不含 `/` 与 `\` → 当作 gav；
- 其余 → 本地文件（做 `file://`、`~`、`${VAR}` 展开）。

每行首尾空白会被去除，空行会被忽略；完全相同的行只保留第一条（不支持 `#` 注释行）。

## 在构建端生成

### Maven

用 beangle maven 插件在打包期生成依赖文件（与 beangle/boot 相同）：

```xml
<plugin>
  <groupId>org.beangle.maven</groupId>
  <artifactId>beangle-maven-plugin</artifactId>
  <version>0.3.32</version>
  <executions>
    <execution>
      <id>generate</id>
      <phase>compile</phase>
      <goals>
        <goal>dependencies</goal>
      </goals>
    </execution>
  </executions>
</plugin>
```

普通 jar 工程在 `maven-jar-plugin` 的 manifest 里配 `Main-Class`；war 工程用
`maven-war-plugin` 的 `packagingExcludes` 避免把依赖打回 `WEB-INF/lib`。

### Sbt

```text
project/plugin.sbt:
  addSbtPlugin("org.beangle.build" % "sbt-beangle-build" % "0.1.5")

build.sbt:
  Compile / packageBin / packageOptions +=
    Package.ManifestAttributes(java.util.jar.Attributes.Name.MAIN_CLASS -> "org.your.main")
  Compile / compile := (Compile / compile).dependsOn(BootPlugin.generateDependenciesTask).value
```

## 依赖布局与校验

gav 构件按 Maven2 布局落到本地仓库：

```text
<local>/<group 以 . 转 />/<artifact>/<version>/<artifact>-<version>[-classifier].<packaging>
<local>/org/slf4j/slf4j-api/2.0.17/slf4j-api-2.0.17.jar
<local>/net/sf/json-lib/json-lib/2.4/json-lib-2.4-jdk15.jar
```

对应 `.sha1` 文件（如 `...jar.sha1`）用于完整性校验：sha1 内容取第一个空白分隔的
40 位十六进制串，与文件实际摘要（小写）比对；不一致视为损坏，删除后从下一远程重下。
