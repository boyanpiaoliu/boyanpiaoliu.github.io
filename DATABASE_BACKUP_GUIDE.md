# 云朵岛数据库备份与恢复

## 当前情况

Supabase 组织目前为 Free 计划。Free 计划不提供 Supabase 托管的自动每日数据库备份；本仓库已加入 GitHub Actions 异地备份工作流，但**必须先配置下面两个 GitHub Actions Secrets，工作流才会真正开始成功备份**。

## 一次性配置

打开 GitHub 仓库：

Settings → Secrets and variables → Actions → New repository secret

添加：

1. `SUPABASE_DB_URL`：Supabase 项目 Dashboard → Connect → Session pooler 的 PostgreSQL 连接字符串。使用数据库密码替换占位符。不要把连接字符串写入代码、聊天或公开文件。
2. `BACKUP_ENCRYPTION_PASSPHRASE`：自行生成一条足够长的随机密码（建议至少 32 个随机字符）。请单独保存在密码管理器或离线安全位置。**丢失它就无法解密备份。**

不要把 Supabase 的 service_role key 放进这里；备份使用数据库连接字符串。

## 自动备份策略

- 每天北京时间 03:17 自动执行。
- 也可以在仓库 Actions → Cloud Island database backup → Run workflow 手动触发。
- 备份内容：数据库角色定义、数据库结构、业务数据、Supabase migration history。
- 上传前使用 OpenSSL AES-256-CBC + PBKDF2 加密。
- GitHub Actions Artifact 保存 30 天。
- 工作流失败时会显示红色失败状态；检查该次运行日志。

注意：数据库备份不包含 Storage API 中实际存储的图片、视频等对象文件。它也不是 Supabase 官方托管备份。GitHub Artifact 有 30 天保留期，重要备份应定期下载到独立的安全存储位置。

## 恢复流程（不要直接覆盖生产库）

1. 在 GitHub Actions 的成功运行记录中下载对应的加密 Artifact。
2. 在可信任的本地电脑上解密。把密码放在环境变量中，不要直接写进命令历史：

```bash
export BACKUP_ENCRYPTION_PASSPHRASE='你的备份密码'
openssl enc -d -aes-256-cbc -pbkdf2 -iter 250000 \
  -pass env:BACKUP_ENCRYPTION_PASSPHRASE \
  -in cloud-island-db-backup-时间戳.tar.gz.enc \
  -out cloud-island-db-backup.tar.gz
mkdir restore && tar -xzf cloud-island-db-backup.tar.gz -C restore
(cd restore && sha256sum -c SHA256SUMS)
```

3. 优先创建一个新的 Supabase 项目作为恢复目标，确认 PostgreSQL 主版本兼容，并先检查备份文件。
4. 使用 Supabase 官方 CLI/PSQL 恢复指南恢复角色、结构、数据和 migration history。不要在生产项目上直接执行旧备份恢复，因为恢复会覆盖当前数据库状态。
5. 单独恢复 Storage 对象，并检查 Storage bucket、RLS、Realtime publication、Auth 设置和 Edge Functions。
6. 完成验证后，再制定生产切换方案。

官方恢复说明：https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore

## 验收标准

- GitHub Secrets 已配置。
- 手动运行工作流显示绿色成功。
- Artifact 中只有加密文件（`.tar.gz.enc`），没有明文 SQL。
- 下载后能够使用密码解密，并通过 SHA-256 校验。
- 至少在独立测试项目完成一次恢复演练。
