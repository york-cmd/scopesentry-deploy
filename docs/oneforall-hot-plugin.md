# OneForAll 热插件

## 运行模式

OneForAll 热插件属于 `SubdomainScan` 模块，默认只做被动候选收集：

```text
--brute False --dns False --req False --takeover False
```

插件不使用 OneForAll 做 DNS 解析；它只读取 OneForAll 输出的 `subdomain` 字段，然后交给 ScopeSentry 自己的 DNS 链路解析和入库。

## 镜像环境

扫描 app 镜像会预装：

```text
/apps/ext/oneforall/OneForAll
/apps/ext/oneforall/venv
/apps/ext/oneforall/venv/bin/python
```

重建命令：

```bash
./devctl scan rebuild
./devctl scan reload
```

不需要为了 OneForAll 重建 `scan base`。只有系统依赖、Chromium、puredns/massdns 等底层依赖变化时才需要 `./devctl scan rebuild-base`。

`./devctl scan rebuild` 会优先复用 `ScopeSentry-Scan/third_party/oneforall.tar.gz`，该文件存在时不会重复下载 OneForAll 源码包。

## 热插件源码

模板位置：

```text
ScopeSentry-Scan/plugin-template/SubdomainScan/oneforall.go
```

上传到平台时建议：

```text
Name: oneforall
Module: SubdomainScan
Hash: eee752d0d592d5628a039038faf94f8e
Default params: -timeout 20 -path /apps/ext/oneforall/OneForAll -python /apps/ext/oneforall/venv/bin/python
```

参数化元数据文件：

```text
ScopeSentry-Scan/plugin-template/SubdomainScan/oneforall.info.json
```

源码文件：

```text
ScopeSentry-Scan/plugin-template/SubdomainScan/oneforall.go
```

## 可选参数

```text
-timeout 20
-path /apps/ext/oneforall/OneForAll
-python /apps/ext/oneforall/venv/bin/python
```

`timeout` 单位为分钟。

## 导入方式

平台导入接口需要传入：

```text
json: oneforall.info.json 的完整 JSON 字符串
source: oneforall.go 的完整源码
isSystem: false
key: ScopeSentry/PLUGINKEY 内容
```

导入后会按 `hash` 做 upsert；重复导入会更新同一个热插件，不会生成多个重复插件。

## 手动验证

进入扫描容器后执行：

```bash
cd /apps/ext/oneforall/OneForAll
/apps/ext/oneforall/venv/bin/python oneforall.py --target example.com --brute False --dns False --req False --takeover False --fmt json --path /tmp/oneforall-check run
```

预期：命令成功结束，并在 `/tmp/oneforall-check` 下生成 JSON 结果文件。
