# EasyTalk（轻松英语交流助手）— 第一阶段原型

面对面英语对话时，在手机上实时显示：

- 双方的英文字幕，自动区分说话人（点标签把自己标成「我」）
- 对方的话配**大字中文翻译**；数字、时间高亮；听不清的词加下划线
- 对方说完一轮后，自动给出 3 条**建议回答**（英文 + 中文），点一下可朗读
- 快捷短语：请再说一遍、请说慢一点……点一下用英语朗读

不保存录音，也不保存对话记录；刷新页面即清空。

## 架构

```text
iPhone Safari  ──(麦克风 PCM，临时 Key)──▶  Soniox stt-rt-v5（转写 + 区分说话人 + 英译中）
      │
      └──(访问口令 Cookie)──▶ https://easytalk.edmondxu.com ─ Cloudflare Tunnel ─▶ 127.0.0.1:8791
                                   server/app.py
                                   ├─ /api/soniox-key  用钥匙串里的 Soniox Key 换 60 秒临时 Key
                                   └─ /api/suggest     用自己的 ChatGPT 套餐生成建议回答（SSE 流式）
```

- 音频直接从手机发到 Soniox，不经过本服务器。
- ChatGPT 是 EasyTalk 自己的 Sign in with ChatGPT 登录，和 CrossBorder AI、HereToBuy 分开，
  互不影响（refresh token 会轮换，多个应用共用一套会互相踢掉）。

## 钥匙串里的密钥（服务名 `com.edmondxu.easytalk`）

| 账户 | 内容 |
|---|---|
| `soniox-api-key` | Soniox 长期 API Key |
| `access-passcode` | 网页访问口令（改口令后所有已登录设备需要重新输入） |
| （服务 `com.edmondxu.easytalk.chatgpt-account`） | ChatGPT 登录凭据，由 `scripts/chatgpt_signin.py` 写入 |

设置或更换（会提示输入两次，屏幕不显示）：

```bash
security add-generic-password -s com.edmondxu.easytalk -a access-passcode -U -w
```

## 安装与运行

```bash
cd /Users/edmond/01_Projects/easytalk
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python -m pytest -q                 # 服务端测试
node tests/test_frontend_logic.js             # 前端逻辑测试（需要 Node）

.venv/bin/python scripts/chatgpt_signin.py    # 一次性：连接 ChatGPT
.venv/bin/python scripts/bench_models.py      # 测各模型速度，选最快的
.venv/bin/python scripts/chatgpt_signin.py use <模型>

.venv/bin/python scripts/run_server.py        # 本机试用：http://127.0.0.1:8791
```

## 成本

- Soniox 实时转写 + 翻译：约每小时 0.18 美元（以 Soniox 控制台为准）。临时 Key 单次有效，
  每次会话最长 3 小时。
- 建议回答：计入 ChatGPT Plus 套餐额度。

## 已知限制（第一阶段）

- iPhone 锁屏或切到别的 App 时，网页收音会中断（第三阶段做原生 App 解决）。
- 断线自动重连后，说话人编号会重置，需要重新标一次「我」。
- 连着麦克风时，iPhone 朗读声音可能从听筒出、比较小，需要实测。
- 区分说话人在声音相近、话很短或很吵时会出错，可以点标签手动纠正。
