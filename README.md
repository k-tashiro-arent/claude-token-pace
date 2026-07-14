# claude-token-pace

*日本語 | [English](README.en.md)* ・ バージョン **0.1.2**（SemVer）

Claude Code の**トークン消費ペース**（5時間枠・7日枠のレート制限 used%）を、ブラウザでインタラクティブに表示するツールです。ローカル HTTP で配信し、**標準ペース（even pace）との乖離**を色と数値で確認できます。

![トークン消費ペースビューア](docs/screenshot.png)

- **used 線**: レート枠の使用率（%）。pace 乖離に応じて 青（遅れ）〜灰（標準どおり）〜赤（先行）に着色。
- **even pace（点線）**: 標準消費ペース。5h は均等直線、7d は就業時間ベースの階段。
- **now 線**: 現在時刻（毎秒更新）。ホバーで各時点の used / even / pace 乖離を表示。

上段 = 5h 枠（次の 5h リセットまでの5時間）、下段 = 7d 枠（次の 7d リセットまでの7日間）。

## 動作環境
- **OS**: Linux / macOS / WSL2（**Windows ネイティブは対象外**）
- **依存**: `python3`、`jq`、任意のブラウザ
- レート制限（5h/7d 枠）のデータは、**5時間・7日の使用量上限がある Claude.ai のサブスクリプション契約（Pro / Max / Team など）**で、かつ**そのセッションで最初のモデル応答があった後**に取得できます（応答前はビューアが「データ収集中…」を表示）。

## インストール
### 方法A: ワンライナー（curl→bash・推奨）
```bash
curl -fsSL https://raw.githubusercontent.com/k-tashiro-arent/claude-token-pace/main/bootstrap.sh | bash
```
内部でリポジトリを一時ディレクトリに clone し、install を実行します（依存: `git`・`python3`・`jq`）。固定版を入れるには:
```bash
curl -fsSL https://raw.githubusercontent.com/k-tashiro-arent/claude-token-pace/main/bootstrap.sh | TOKEN_PACE_REF=v0.1.0 bash
```

### 方法B: git clone（更新を `git pull` で行いたい場合）
```bash
git clone https://github.com/k-tashiro-arent/claude-token-pace.git
cd claude-token-pace
./install.sh
```

どちらの方法でも、インストーラは次を行います:
1. スクリプト/ビューアを `~/.claude/token-pace/` に配置
2. 既定の `config.json` / `biz-hours.json` を配置（既存があれば保持）
3. スラッシュコマンド `/tpw` を `~/.claude/commands/` に設置
4. **statusLine を「ラッパー」に差し替え**（`settings.json` をバックアップ）。ラッパーは statusLine の JSON を記録用サンプラに渡しつつ、**既存の statusLine 表示はそのまま通します**。

> 設置先を変えたい場合: `TOKEN_PACE_DIR=/path/to/dir ./install.sh`

## アップデート
- **curl 方式**: 同じワンライナーを再実行するだけ（毎回クローンし直して install）。
- **git clone 方式**: クローンを更新して再実行:
  ```bash
  cd claude-token-pace
  git pull
  ./install.sh
  ```

`install.sh` は冪等です。プログラム（`bin/`・`index.html`）を上書きし、あなたの設定（`config.json`・`biz-hours.json`）は保持し、statusLine は既にラップ済みなら変更しません。更新時は `v旧 → v新` を表示します（インストール版数は `~/.claude/token-pace/.version` に記録）。

## 使い方
Claude Code で:
```
/tpw
```
ローカル HTTP サーバ（`127.0.0.1`）が起動し、既定ブラウザでビューアが開きます。ビューアは数秒ごとに自動反映します。

## データの取得と蓄積
- 使用量は **Claude Code を使用している間、自動で**（ステータス行 statusLine が更新されるたびに）記録されます。記録は約 30 秒に 1 回へ間引かれ、グラフ（`pace.json`）は約 3 分ごとに再生成されます。
- 記録が始まるのは、**そのセッションで最初のモデル応答があった後**です。応答前やアイドル中は使用量が変化しないため記録されません（応答前はビューアが「データ収集中…」を表示）。
- データは**インストールした環境ごとにローカルに蓄積**されます（`~/.claude/token-pace/pace.jsonl`）。複数マシンで使っても履歴は共有されず、各環境が独立に貯めます。インストール直後は履歴が無いため、特に 7d パネルは使い込むほど埋まっていきます。

## 設定
### ポート（`~/.claude/token-pace/config.json`）
```json
{ "port": 8799 }
```
解決順: 環境変数 `TOKEN_PACE_PORT` > `config.json` の `port` > 既定 `8799`。指定ポートを優先し、埋まっていれば近傍を自動スキャンして起動します。

### 就業時間（`~/.claude/token-pace/biz-hours.json`）
7d パネルの even pace（標準ペース）の基準です。
```json
{ "biz_days": [1, 2, 3, 4, 5], "biz_start_hour": 9, "biz_end_hour": 18 }
```
- `biz_days`: 就業曜日（1=月 … 7=日）
- `biz_start_hour` / `biz_end_hour`: 就業時刻（JST、小数可）

## データの場所
`~/.claude/token-pace/`（`pace.jsonl` = 記録、`pace.json` = ビューア入力、`index.html`、各種設定・状態ファイル）。`127.0.0.1` バインドなので LAN には露出しません。

## アンインストール
```bash
bash ~/.claude/token-pace/uninstall.sh
```
statusLine を元に戻し、`/tpw` コマンドを削除、稼働中サーバを停止します（記録データは残します。完全削除は `rm -rf ~/.claude/token-pace`）。

## トラブルシューティング
- **ブラウザが開かない**: Linux は `xdg-open`、macOS は `open`、WSL は `powershell.exe` を使用。無い場合は表示された URL を手動で開いてください。
- **「データ収集中…」のまま**: まだ記録が始まっていません（そのセッションでまだ応答が無い/レート制限データ未取得）。Claude Code で1ターン操作して数分待ち、対象の契約か（「動作環境」を参照）も確認してください。
- **ポートが埋まっている**: 指定＋近傍を自動スキャンして起動します。固定したい場合は `config.json` の `port` を変更。

## ライセンス
[MIT](LICENSE)
