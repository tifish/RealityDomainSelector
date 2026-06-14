# RealityDomain

从 Tranco Top 1M 域名列表中随机筛选候选域名，并使用 `RealiTLScanner.exe` 验证 TLS/REALITY 相关可用性。

## 文件说明

| 文件 | 说明 |
| --- | --- |
| `top-1m.csv` | Tranco 下载的网站排名列表，格式为 `rank,domain`。 |
| `RealiTLScanner.exe` | 用于验证域名 TLS 信息的扫描工具。 |
| `Country.mmdb` | 扫描器使用的地理/网络归属数据库。 |
| `Update-TrancoTop1M.ps1` | 下载并解压最新 Tranco `top-1m.csv` 的脚本。 |
| `Select-RealityDomains.ps1` | 当前工程的筛选与扫描脚本。 |
| `tranco-downloads/` | Tranco 下载脚本的运行摘要和临时下载目录。 |
| `reality-scan-results/` | 脚本运行后生成的结果目录。 |

## 筛选逻辑

默认规则：

- 排名范围：`5,000` 到 `300,000`
- 随机选择：`100` 个域名
- 排除过热大站：`google`、`facebook`、`youtube`、`cloudflare`、`microsoft`、`apple` 等
- 排除敏感类别：AI、社交、成人、博彩、加密货币、政治、下载盗版
- 优先保留：`docs`、`static`、`assets`、`download`、`dl`、`support`、`help`、`developer`、`mirrors`、`cdn`

扫描后的可用结果默认还会满足：

- `TLS` 为 `TLS 1.3`
- 证书域名字段不为空
- 扫描结果的 `ORIGIN` 必须是本次随机选中的域名
- 排除 `GEO_CODE` 为 `CLOUDFLARE`、`GOOGLE`、`FACEBOOK`、`MICROSOFT`、`APPLE` 的结果

## 更新 Tranco 数据

在筛选域名前，可以先拉取最新 Tranco Top 1M 列表：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Update-TrancoTop1M.ps1
```

默认下载地址：

```text
https://tranco-list.eu/top-1m.csv.zip
```

脚本会自动完成：

- 下载 `top-1m.csv.zip`
- 解压出 `top-1m.csv`
- 校验基本 `rank,domain` 格式和行数
- 用最新列表替换当前 `top-1m.csv`
- 在 `tranco-downloads/<时间戳>/summary.txt` 记录本次下载摘要

常用参数：

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-DownloadUrl` | `https://tranco-list.eu/top-1m.csv.zip` | Tranco zip 下载地址。 |
| `-ListIdUrl` | `https://tranco-list.eu/top-1m-id` | 最新列表 ID 查询地址。 |
| `-OutputCsv` | `.\top-1m.csv` | 解压后的 CSV 输出路径。 |
| `-DownloadDir` | `.\tranco-downloads` | 下载脚本的工作目录。 |
| `-Retries` | `3` | 下载失败重试次数。 |
| `-TimeoutSec` | `180` | 单次请求超时时间。 |
| `-KeepZip` | 关闭 | 保留下载的 zip 文件。 |

## 筛选域名

在当前目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Select-RealityDomains.ps1
```

脚本会自动读取：

- `.\top-1m.csv`
- `.\RealiTLScanner.exe`

并把结果写入：

```text
.\reality-scan-results\<时间戳>\
```

## 输出文件

每次运行都会生成一个独立的时间戳目录，包含：

| 文件 | 说明 |
| --- | --- |
| `selected-domains.txt` | 本次随机抽中的域名，一行一个，可直接作为扫描器输入。 |
| `selected-domains.csv` | 本次随机抽中的域名，包含排名和优先命中原因。 |
| `scanner-raw.csv` | `RealiTLScanner.exe` 原始输出。 |
| `usable-results.csv` | 按脚本规则过滤后的可用结果明细。 |
| `usable-domains.txt` | 去重后的可用域名列表。 |
| `summary.txt` | 本次运行摘要，包括候选数量、排除数量、可用数量和输出路径。 |

## 常用参数

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-MinRank` | `5000` | Tranco 最小排名。 |
| `-MaxRank` | `300000` | Tranco 最大排名。 |
| `-SampleCount` | `100` | 随机选择的域名数量。 |
| `-Thread` | `16` | `RealiTLScanner` 并发数。 |
| `-Timeout` | `8` | 单个检测超时时间，单位由扫描器定义。 |
| `-Port` | `443` | HTTPS 端口。 |
| `-RequireTls13` | `$true` | 是否只保留 `TLS 1.3`。 |
| `-RequireCertDomainMatch` | `$false` | 是否要求证书域名和 `ORIGIN` 匹配。 |
| `-ExcludedGeoCodes` | `CLOUDFLARE, GOOGLE, FACEBOOK, MICROSOFT, APPLE` | 扫描结果中需要排除的网络归属。 |
| `-IncludeIpv6` | 关闭 | 启用扫描器的 `-46` 参数，同时检测 IPv6。 |
| `-SkipScan` | 关闭 | 只生成随机候选，不调用扫描器。 |
| `-Seed` | `0` | 随机种子；设置后可复现同一批候选。 |

## 示例

只生成候选，不扫描：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Select-RealityDomains.ps1 -SkipScan
```

固定随机种子，便于复现：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Select-RealityDomains.ps1 -Seed 20260614
```

提高并发并缩短超时：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Select-RealityDomains.ps1 -Thread 32 -Timeout 6
```

要求证书域名匹配：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Select-RealityDomains.ps1 -RequireCertDomainMatch $true
```

不按 `GEO_CODE` 排除热网络：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Select-RealityDomains.ps1 -ExcludedGeoCodes @()
```

## 注意事项

- Tranco 原始列表通常只包含根域名或主域名，不一定包含 `docs.example.com` 这类子域名；优先关键词只会匹配列表中实际存在的域名字符串。
- 随机样本可能一次没有可用结果，直接重新运行脚本即可抽取新样本。
- 扫描会产生真实网络请求，建议只在合规网络环境中使用。
- `usable-domains.txt` 是最便于后续人工复核的结果入口，最终使用前仍建议手动检查域名业务类型、访问稳定性和证书信息。
