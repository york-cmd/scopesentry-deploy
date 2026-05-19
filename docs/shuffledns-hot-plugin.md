# shuffleDNS 热插件

## 运行模式

shuffleDNS 热插件属于 `SubdomainScan` 模块，默认使用 `bruteforce` 模式：

```text
shuffledns -d <domain> -w <wordlist> -r <resolvers> -m <massdns> -mode bruteforce
```

插件复用扫描镜像内置的 `massdns` 与 resolver 文件，输出结果再交给 ScopeSentry 的 DNS 链路补充解析和入库。

## 镜像环境

扫描 app 镜像会预装：

```text
/apps/ext/shuffledns/shuffledns
/apps/ext/puredns/massdns
/apps/ext/puredns/resolvers.txt
```

重建命令：

```bash
./devctl scan rebuild
./devctl scan reload
```

## 热插件源码

模板位置：

```text
ScopeSentry-Scan/plugin-template/SubdomainScan/shuffledns/plugin.go
```

参数化元数据：

```text
ScopeSentry-Scan/plugin-template/SubdomainScan/shuffledns/info.json
```

默认导入参数：

```text
-wordlist {dict.subdomain.default} -timeout 60 -threads 10000 -shuffledns /apps/ext/shuffledns/shuffledns -massdns /apps/ext/puredns/massdns -resolver /apps/ext/puredns/resolvers.txt
```

## 可选参数

```text
-wordlist /path/to/subdomains.txt
-subfile /path/to/subdomains.txt
-timeout 60
-et 60
-threads 10000
-t 10000
-shuffledns /apps/ext/shuffledns/shuffledns
-massdns /apps/ext/puredns/massdns
-resolver /apps/ext/puredns/resolvers.txt
-resolvers /apps/ext/puredns/resolvers.txt
```

`timeout`/`et` 单位为分钟。
