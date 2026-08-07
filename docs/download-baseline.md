# 官网下载总数基线(2026-08-07)

官网下载计数器(`api.tokenremain.com/v1/downloads/stats`)于 2026-07-25 才开始
计数,此前的官网下载都直接落在 GitHub Release 的固定文件名资产
`TokenRemain.dmg` 上——官网下载按钮自 v1.0.0 起始终指向该文件。因此以该资产
在全部 Release 上的累计下载数作为官网完整历史总数的基线,通过迁移
[`broadcast/migrations/0005_download_baseline.sql`](../broadcast/migrations/0005_download_baseline.sql)
一次性写入计数器,此后由官网匿名聚合计数器继续累计。

- **基线**:`TokenRemain.dmg` 全量历史累计 **163** 次(GitHub Releases API,
  抓取于 2026-08-07)。
- **不叠加旧计数**:计数器已有的 13 次(2026-07-25 起)本身就包含在这 163 次
  之内(官网 302 跳转到同一 GitHub 资产),所以迁移是"抬升到 163",不是
  "163 + 13"。
- **不计入**:按版本命名的 `TokenRemain-x.y.z-build.dmg`(用户在 GitHub
  Release 页直接下载,共 21 次,合计口径为 184)、`*-macOS.zip`(Sparkle
  自动更新包)、`appcast.xml` 与 `SHA256SUMS.txt`。

## 抓取当日的逐版本明细(TokenRemain.dmg / 版本命名 DMG)

| Release | TokenRemain.dmg | 版本命名 DMG |
| :-- | --: | --: |
| v1.2.10 | 2 | 2 |
| v1.2.9 | 7 | 1 |
| v1.2.8 | 3 | 1 |
| v1.2.7 | 16 | 3 |
| v1.2.6 | 22 | 4 |
| v1.2.5 | 11 | 1 |
| v1.2.4 | 1 | 1 |
| v1.2.3 | 3 | 1 |
| v1.2.2 | 7 | 1 |
| v1.2.1 | 30 | 3 |
| v1.2.0 | 15 | 2 |
| v1.1.11 | 14 | 1 |
| v1.1.10 | 4 | 0 |
| v1.1.9 | 2 | 0 |
| v1.1.8 | 1 | 0 |
| v1.1.7 | 1 | 0 |
| v1.1.6 | 5 | 0 |
| v1.1.5 | 2 | 0 |
| v1.1.4 | 3 | 0 |
| v1.1.3 | 2 | 0 |
| v1.1.2 | 4 | 0 |
| v1.1.1 | 2 | 0 |
| v1.1.0 | 1 | 0 |
| v1.0.0 | 5 | 0 |
| **合计** | **163** | **21** |

复现命令:

```bash
gh api repos/Carstin520/token-remain/releases --paginate \
  --jq '[.[] | .assets[] | select(.name == "TokenRemain.dmg") | .download_count] | add'
```
