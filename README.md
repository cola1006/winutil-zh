# winutil-zh — 繁體中文版 WinUtil（自動同步上游）

自動把 [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil) 繁體中文化，
並**每日重新建置**，讓中文版 `winutil.ps1` 永遠有一個固定的 raw 網址、且自動跟上上游更新。

## 一鍵執行（繁體中文版）

```powershell
irm "https://raw.githubusercontent.com/cola1006/winutil-zh/main/winutil.ps1" | iex
```

固定 raw 網址：

```
https://raw.githubusercontent.com/cola1006/winutil-zh/main/winutil.ps1
```

## 運作方式

GitHub Actions 每天（UTC 18:00）自動：

1. Checkout 本 repo 與最新的上游 `ChrisTitusTech/winutil`。
2. 執行 `translate/apply-translations.py`，用「字典／差異替換」把中文套到上游原始檔。
3. 用上游官方 `Compile.ps1`（Windows + pwsh，UTF-8）編譯出 `winutil.ps1`。
4. 若內容有變動就 commit 回本 repo。

也可到 Actions 頁手動 `Run workflow`（`workflow_dispatch`）立即重建。

## 翻譯機制（為什麼用差異替換而不是整檔覆蓋）

上游天天改，整檔覆蓋很快就會失效，所以採「只替換已知字串」的方式，
未知／新增的內容會自動保留英文，不會弄壞程式：

- **`config/*.json`**：欄位範圍字典替換（`translate/config-dict.json`，483 條）。
  只翻指定欄位：
  - `applications.json` → `description`, `category`
  - `tweaks.json` → `Content`, `Description`, `category`
  - `feature.json` → `Content`, `Description`, `category`
  - `appx.json` / `appnavigation.json` → `Content`, `Description`, `Category`
- **`xaml/inputXML.xaml`**：以 difflib 產生的精確 `{old,new}` 原始字串配對（`translate/xaml-pairs.json`）。
- **`functions/*.ps1`**：同樣的差異配對（`translate/functions-pairs.json`）。

所有檔案一律 UTF-8 讀取、UTF-8（無 BOM）寫回。

### 已知限制

- **上游新增／改動的字串會先以英文出現。** 因為配對是針對已知的英文原文；
  上游一旦改了某段文字，對應的 pair 就會 miss 並保留英文（fallback），
  等字典／pairs 更新後才會中文化。
- **分頁標題（TabItem Header）刻意保持英文**（`Install` / `Tweaks` / `Config` /
  `Updates` / `Win11ISO` / `AppX`），因為 `Invoke-WPFTab.ps1` 用 Header 當程式邏輯的判斷鍵，
  翻成中文會讓分頁切換失效。

## 更新翻譯

重新產生 pairs（在有翻譯工作區的來源 repo 上）：

```bash
python translate/gen-pairs.py
```

字典 `translate/config-dict.json` 可直接編輯（英文原字串 → 中文）。

---

> 本 repo 僅做中文化與自動重建，所有功能與程式邏輯皆來自上游
> [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil)（MIT License）。
