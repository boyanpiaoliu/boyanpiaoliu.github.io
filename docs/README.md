# 云朵岛项目说明

## 一、产品定位

云朵岛是一款以漂流瓶为入口的轻社交应用，围绕陌生人故事、好友交流、心情动态和个人主页装饰展开。

## 二、当前技术架构

- 前端：HTML、CSS、JavaScript
- 身份认证：Supabase Auth
- 数据库：Supabase PostgreSQL
- 文件存储：Supabase Storage
- 实时消息：Supabase Realtime
- 代码托管与静态网站：GitHub Pages

## 三、核心功能

1. 邮箱及手机号注册、登录
2. 漂流瓶投递、收取与回复
3. 好友申请和好友管理
4. 私信聊天与消息已读状态
5. 心情动态、评论、点赞和收藏
6. 个人资料、头像及主页装饰
7. 云朵币、会员权益展示
8. 举报、拉黑和账号安全
9. 多语言界面

## 四、数据库与安全

- 业务数据通过 Supabase 管理。
- 公开数据访问由 Row Level Security（RLS）策略控制。
- 敏感操作应使用经过身份校验的数据库函数或服务端逻辑。
- 禁止将 service_role key、数据库密码、支付密钥或其他 Secret Key 写入前端或公开仓库。
- 数据库备份与恢复流程见仓库根目录的 DATABASE_BACKUP_GUIDE.md。

## 五、发布说明

正式网站部署在 GitHub Pages。修改主页面后，等待 GitHub Pages 部署完成，再通过正式网址检查登录、消息、漂流瓶、动态和个人主页等主要流程。
