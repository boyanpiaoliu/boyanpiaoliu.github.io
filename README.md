# 云朵岛

云朵岛是一款以漂流瓶、陌生人交流、好友私信和心情分享为核心的轻社交应用。

## 项目入口

- 正式网站：https://boyanpiaoliu.github.io/
- 前端：HTML、CSS、JavaScript
- 后端：Supabase（Auth、PostgreSQL、Storage、Realtime）
- 数据库迁移目录：supabase/
- 项目说明：docs/README.md

## 主要功能

- 邮箱及手机号注册、登录
- 漂流瓶投递与收取
- 好友、私信和消息通知
- 心情动态、收藏与互动
- 个人主页、头像及主题装饰
- 云朵币与会员展示
- 举报、拉黑及账号安全设置

## 安全说明

前端只使用 Supabase publishable key。数据库权限以 RLS 和受控 RPC 为准；任何服务端密钥、数据库密码和第三方 Secret Key 均不得提交到仓库。
