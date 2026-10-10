# coding-plan-usage

[English](README.md) | 简体中文

Omarchy 状态栏插件，展示各 LLM 平台的 coding-plan 配额用量。

![面板](preview.png)

- 栏上：一个图标 + 最紧张（用量最高）窗口的百分比，如 `󰹊 42%`
  （余额类平台显示金额，如 ` ¥110.00`）
- 弹窗（点击）：所有已启用平台自上而下排列，每个平台展示各窗口用量、
  进度条、重置时间 + 倒计时、已用/总额 token、分模型明细、API key 管理
- 告警配色：< 70% 正常，>= 70% accent，>= 90% urgent

## 安装

```sh
omarchy plugin add https://github.com/xpader/omarchy-coding-plan-usage.git --enable
```

然后把组件加入栏布局，并在 `~/.config/omarchy/shell.json` 中配置
平台开关与刷新间隔（见下文）。

## 结构

```
manifest.json          插件清单（bar-widget）
Panel.qml              全部 UI — 栏上胶囊 + 弹窗；与平台无关
Providers.qml          平台注册表 + 聚合（抽象接缝）
Util.js                共享格式化工具（可用 node 测试）
providers/
  glm/
    GlmProvider.qml    GLM 提供方：key 存储、刷新、请求
    Model.js           GLM API 响应 → 归一化窗口（可用 node 测试）
  deepseek/
    DeepseekProvider.qml  DeepSeek 余额提供方
    Model.js              /user/balance 解析（可用 node 测试）
```

Panel.qml 只渲染**提供方契约**，从不直接访问平台 API。每个提供方必须暴露：

```
providerId / providerName / iconGlyph / keyLabel
state        "no-key" | "loading" | "ok" | "error"
statusText   错误或临时提示（正常时为 ""）
planLabel    从平台获取的套餐/档位名（未知时为 ""）
windows      [{ id, title, percent (0-100, -1 未知), resetAtMs,
                used, limit, details: [{ name, value }] }]
             余额类条目用 kind: "balance"、valueText ("¥110.00")，
             不显示百分比进度条
headlinePercent   最紧张窗口的百分比，-1 未知
barLabel     余额类平台在栏上胶囊显示的文本（替代百分比）
updatedAtMs / refreshing / hasApiKey
refresh() / setKey(key) / clearKey()
```

## 添加新平台

1. 创建 `providers/<id>/<Id>Provider.qml` 实现上述契约
   （GlmProvider.qml 是参考实现）。
2. 在 `providers/<id>/Model.js` 中添加解析辅助函数（纯函数，
   导出以便 node 测试）。
3. 在 `Providers.qml` → `registry` 中注册。

在 `~/.config/omarchy/shell.json` 中开关平台：

```json
{ "id": "pader.coding-plan-usage",
  "providers": { "glm": { "enabled": true } } }
```

## API key

按提供方分别存储于
`~/.local/state/omarchy/coding-plan-usage/keys/<id>`（权限 600）。
可在弹窗的 API KEY 区设置/删除，或手动写入：

```bash
umask 077 && mkdir -p ~/.local/state/omarchy/coding-plan-usage/keys
echo -n 'YOUR_KEY' > ~/.local/state/omarchy/coding-plan-usage/keys/glm
```

key 只存在于磁盘和内存中：请求通过 QML 内置的 `XMLHttpRequest` 发出
（无 curl 子进程，key 不会出现在任何 argv 里）。

## GLM API

`GET https://open.bigmodel.cn/api/monitor/usage/quota/limit`，请求头
`Authorization: <apiKey>`。按 `nextResetTime` 排序的 `TOKENS_LIMIT` 条目
分别是滚动 5 小时窗口（第一条）和周窗口（最后一条）；`TIME_LIMIT` 是
月度 MCP 额度。参考：github.com/xpader/glm-usage。

## DeepSeek API

`GET https://api.deepseek.com/user/balance`，请求头
`Authorization: Bearer <key>`。CNY `balance_infos` 求和作为总额；
`granted_balance` / `topped_up_balance` 显示为明细。
参考：VSCode 插件 "DeepSeek Balance Display"
（shaoclouds.deepseek-balance-display）。

## IPC

```
omarchy-shell pader.coding-plan-usage open|close|toggle|refresh|status
```

面板按键：`j/k` 滚动，`Enter`/`r` 刷新，`e` 打开第一个缺 key 提供方的
key 编辑框，`Esc` 关闭。

## 注意事项

- 修改后执行 `omarchy restart shell`：插件支持热重载，但内部文件可能
  命中缓存文档；重启总是能干净地生效。

## 卸载

```sh
omarchy plugin remove pader.coding-plan-usage
```

卸载会保留磁盘上已保存的 API key
（`~/.local/state/omarchy/coding-plan-usage/keys/`）；不再需要时可
删除该目录。

## 许可证

[MIT](LICENSE) © Pader
