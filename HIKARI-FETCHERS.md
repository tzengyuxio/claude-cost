# hikari fetchers — 規格與交接

在 hikari（家用 AI 主機）上跑**第二份獨立的 claude-cost**，統計那台機器被使用的量；Mac 上這份維持原樣，統計個人在 Mac 用 Claude Code / Codex 的量。**兩邊的 `usage.db` 完全分開**，不同步、不合併。

撰寫於 2026-08-06。所有 SQL 與路徑都已在實機驗證過，輸出貼在下方。

## 背景：那台機器長什麼樣

hikari 是 Ubuntu 24.04 + RTX 5090 + RTX 3060，跑 Ollama、Open WebUI、ComfyUI、LiteLLM。使用者從兩條路徑進來：

```
家人 / CLI 工具  →  api.umemu.org  →  LiteLLM :4000  →  Ollama       ← 有 API key，記在 PostgreSQL
yuxio 自己       →  Open WebUI :3000              →  Ollama（直連）  ← 繞過 LiteLLM，記在 SQLite
```

**Open WebUI 直連 Ollama，不經 LiteLLM**，這是刻意保留的架構（改走 LiteLLM 會讓 Open WebUI 的模型管理功能失效，還要踩它的 PersistentConfig 陷阱）。代價就是**用量分散在兩個資料庫**，所以需要兩個 fetcher，任何單一的現成工具都涵蓋不了。

## 環境

```
sqlite3   ❌ 要裝    sudo apt update && sudo apt install -y sqlite3
jq        ✅ 已有
git       ✅ 已有
node/npx  ❌ 沒有    → 不需要，見下
psql      主機沒有，只在 litellm-db 容器內 → 用 docker exec
docker    ✅ yuxio 已在 docker 群組，不需要 sudo
```

**不需要 Node。** 這個專案沒有前置依賴檢查，`npx` 只在 `fetchers/claude.sh` 與 `codex.sh` 內部呼叫。hikari 上的 `ENABLED_PROVIDERS` 不含那兩個，就不會執行到。

## 要做的事

### 1. 兩個新 fetcher

命名用 **`litellm`** 與 **`openwebui`**，不要用 `hikari-api` 這種帶連字號的名字——dispatch 是 `fetch_${PROVIDER}` 與 `declare -f`，連字號會讓函式名難以處理。

- `lib/fetchers/litellm.sh` → `fetch_litellm()`
- `lib/fetchers/openwebui.sh` → `fetch_openwebui()`

介面契約照既有的（見 `lib/fetchers/claude.sh`）：

```
fetch_<provider> <last_watermark> <yesterday>
輸出 TSV：date, provider, model, input, output, cache_creation, cache_read, cost
```

兩者都**不實作 `_hourly`**。`bin/claude-cost-collect` 用 `declare -f "fetch_${PROVIDER}_hourly"` 判斷，不存在就跳過，不會報錯。本機模型沒有 cache token 的概念，`cache_creation` 與 `cache_read` 一律填 `0`。

### 2. 掛進 collect

`bin/claude-cost-collect` 第 18–20 行是硬編碼 source，要補兩行：

```bash
. "$_FETCHERS_DIR/litellm.sh"
. "$_FETCHERS_DIR/openwebui.sh"
```

（或改成 `for f in "$_FETCHERS_DIR"/*.sh; do . "$f"; done`，但那會改變既有行為，自行斟酌。）

### 3. 設定

`claude-cost.conf.example` 的 `ENABLED_PROVIDERS` 註解要更新，並加上新變數。hikari 上的 `~/.config/claude-cost/config`：

```sh
TIMEZONE="Asia/Taipei"
ENABLED_PROVIDERS="litellm openwebui"

# 兩個 fetcher 的資料源
LITELLM_DB_CONTAINER="litellm-db"
LITELLM_DB_USER="litellm"
LITELLM_DB_NAME="litellm"
OPENWEBUI_DB="/srv/data/webui/webui.db"
```

---

## fetcher 一：litellm

資料源是 `litellm-db` 容器裡的 PostgreSQL，表 `LiteLLM_SpendLogs`。主機沒有 `psql`，所以走 `docker exec`。

### 已驗證的查詢

```sql
SELECT to_char((s."startTime" AT TIME ZONE 'UTC' AT TIME ZONE '<TIMEZONE>')::date, 'YYYY-MM-DD') AS d,
       COALESCE(NULLIF(s.model_group, ''), s.model) AS m,
       COALESCE(v.key_alias, left(s.api_key, 12)) AS who,
       SUM(s.prompt_tokens), SUM(s.completion_tokens), SUM(s.spend)
FROM "LiteLLM_SpendLogs" s
LEFT JOIN "LiteLLM_VerificationToken" v ON v.token = s.api_key
WHERE s.total_tokens > 0
GROUP BY d, m, who ORDER BY d, m;
```

`key_alias` 讓用量能歸屬到人（`family-kitty` 等），這是 Open WebUI 那邊做不到的維度（那邊只有單一使用者）。**撤銷過的 key 在 `LiteLLM_VerificationToken` 已被刪除**，join 不到就退回顯示 hash 前綴，歸戶時要留意這批孤兒列。

呼叫方式（`-t -A -F$'\t'` 直接給出 TSV，不用再處理）：

```bash
docker exec "$LITELLM_DB_CONTAINER" psql -U "$LITELLM_DB_USER" -d "$LITELLM_DB_NAME" \
    -t -A -F$'\t' -c "$sql"
```

實測輸出：

```
2026-08-05	qwen	60	10096	0
2026-08-05	qwen-tw	934	8098	0
2026-08-06	claude-sonnet-5	276	140	0
2026-08-06	qwen-tw	2099	7238	0
```

### 注意事項

- **`WHERE total_tokens > 0` 不能省。** 實測 39 筆裡有 **19 筆是零 token** 的失敗請求（被 rate limit 擋掉的、`model` 欄位是空字串的）。不濾掉的話請求數會虛高一倍，還會產生 model 為空的垃圾列。
- **用 `model_group` 而不是 `model`。** `model` 存的是後端實際名稱（`ollama_chat/qwen-tw:latest`），`model_group` 是對外的名字（`qwen-tw`）。用 `COALESCE(NULLIF(model_group,''), model)` 兜底。
- **`spend` 永遠是 0**，因為 `litellm-config.yaml` 把 `input_cost_per_token` 設成 0。**不要為了讓報表好看去改那個值**——價格非 0 會讓 LiteLLM 的 budget 機制全部失準（那份 config 的註解有寫）。雲端等價成本要離線另算，見下方「成本」。
- `startTime` 是 UTC 的 `timestamp without time zone`，所以要 `AT TIME ZONE 'UTC' AT TIME ZONE '<TIMEZONE>'` 兩段轉換，不能只寫一段。
- 表名有大寫，SQL 裡**必須用雙引號** `"LiteLLM_SpendLogs"`。在 shell 裡包 SQL 時注意跳脫。
- watermark 用 `AND d > '<last>'` 過濾，`bin/claude-cost-collect` 已經 per-provider 存 watermark，照既有模式即可。

---

## fetcher 二：openwebui

資料源是 `/srv/data/webui/webui.db`（SQLite）。權限是 `root:root 644`，**yuxio 可以直接讀，不需要 sudo 也不需要 docker exec**。

Open WebUI 的訊息存在 `chat_message` 表（不是 `chat` 表——舊版把訊息塞在 `chat` 的 JSON 裡，這個版本已經拆出來了）。相關欄位：

```
id, chat_id, user_id, role, content, output, model_id, usage, created_at, updated_at
```

`usage` 是 JSON 字串，`created_at` 是 unix epoch（秒）。

### 查詢

```sql
SELECT date(created_at, 'unixepoch', 'localtime') AS d,
       model_id,
       SUM(json_extract(usage, '$.prompt_tokens')),
       SUM(json_extract(usage, '$.completion_tokens'))
FROM chat_message
WHERE role = 'assistant' AND usage IS NOT NULL
GROUP BY d, model_id ORDER BY d, model_id;
```

**用唯讀模式開啟**，Open WebUI 隨時可能在寫入：

```bash
sqlite3 "file:${OPENWEBUI_DB}?mode=ro" -separator $'\t' "$sql"
```

`'localtime'` 會用系統時區。若 `TIMEZONE` 與系統時區不同，要改用 `datetime(created_at,'unixepoch')` 取回 UTC 後自行位移，否則日期分組會跟 litellm fetcher 對不齊。hikari 的系統時區是 UTC，而建議的 `TIMEZONE="Asia/Taipei"`，**所以這裡預設就是不一致的，必須處理**。

### ⚠️ 未解：兩組 token 數字要用哪一組

`usage` 裡同時有兩組，數值差很多。實測三筆：

| input_tokens | prompt_tokens | output_tokens | completion_tokens |
|---|---|---|---|
| 14424 | 7362 | 446 | 156 |
| 13623 | 6968 | 384 | 81 |
| 11817 | 5976 | 943 | 603 |

`input_tokens` 大約是 `prompt_tokens` 的兩倍，`output_tokens` 也一致地大於 `completion_tokens`。來源不明——可能是 Open WebUI 自己用別的 tokenizer 估算，也可能一組含 thinking 一組不含。

**建議選 `prompt_tokens` / `completion_tokens`**，理由是與 litellm fetcher 對齊：`LiteLLM_SpendLogs` 用的就是這兩個欄位名，兩邊選同一組，跨 provider 的數字才可比。

但這是推論不是實證。要確定的話，拿一次已知的對話去對照 Ollama 的 `eval_count` / `prompt_eval_count`（`docker logs ollama` 或直接打 `/api/generate` 比對）。**做完把結論寫回這一節。**

### 其他注意事項

- `model_id` 存的是 Ollama 的原始名稱（例如 `qwen-unc:latest`），與 litellm fetcher 的 `qwen-tw` 命名體系不同。要不要正規化（去掉 `:latest`）自行決定，但**兩邊要一致**，否則報表會出現 `qwen-tw` 和 `qwen-tw:latest` 兩列。
- 這條路徑的用量**只有 yuxio 自己**（家人走 API），所以不需要 per-user 拆分；但 `user_id` 欄位存在，日後要拆也拆得出來。
- Open WebUI 生圖也走這張表（`files` 欄位有圖片、`model_id` 是 LLM），**但生圖本身沒有 token 計數**，不會污染統計。

---

## 成本

本機推論的直接成本是 0，兩個 fetcher 的 `cost` 欄位都填 `0`。

若要做「雲端等價成本」（用同樣的 token 數換算成呼叫雲端 API 要花多少），**不要寫進 `cost_usd`**——那個欄位在 Mac 那份是真實花費，語意混在一起後兩邊的報表都會失去意義。建議另外加 `cloud_equivalent_cost` 欄位，費率放 config，離線乘算。

參考值（hikari 那邊的 `docs/risks-and-cost.md` 有記）：開源模型代管約 $0.20/M input、$0.60/M output；前沿模型（Sonnet 級）約 $3/M input、$15/M output。**這兩個費率是假設值，換算時要重新確認。**

## 部署

```bash
# 1. 裝 sqlite3
sudo apt update && sudo apt install -y sqlite3

# 2. clone（public repo，用 https 即可；hikari 的 deploy key 只對 hikari-setup 有效）
git clone https://github.com/tzengyuxio/claude-cost.git ~/lab/claude-cost

# 3. 設定
mkdir -p ~/.config/claude-cost
cp ~/lab/claude-cost/claude-cost.conf.example ~/.config/claude-cost/config
# 編輯成上面「設定」那節的內容

# 4. 首次收集
~/lab/claude-cost/bin/claude-cost-collect

# 5. 排程：share/ 下有 systemd 範本
```

## 驗收

1. `claude-cost-collect` 跑完沒有錯誤，`~/.local/share/claude-cost/usage.db` 的 `daily_usage` 同時有 `litellm` 與 `openwebui` 兩種 provider 的列
2. **重跑一次，列數不變**（`INSERT OR REPLACE` 冪等，既有機制已保證，但要實測確認 watermark 有正確前進）
3. `claude-cost-report` 的日／週／月報表能正常輸出，不會因為 `cost_usd` 全為 0 而崩潰或顯示空白
4. 手動比對一天的數字：LiteLLM 那半邊對照 admin UI（<https://hikari.tail81eb54.ts.net:4000/ui/>，登入 `admin` + master key）看得到的用量

## 相關文件

hikari 那台的正本在 `~/lab/hikari-setup`（Mac）與 `~/lab/hikari-setup`（hikari）。相關的有 `docs/service-stack.md`（LiteLLM 設定與踩過的坑）、`docs/risks-and-cost.md`（成本與功耗實測）、`BACKLOG.md`（「從 SpendLogs 算雲端等價成本」那條就是這件事）。
