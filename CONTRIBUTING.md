# Contributing

Thanks for your interest! / コントリビュート歓迎です。日本語・英語どちらの Issue/PR も歓迎します。

## 開発環境 / Prerequisites
- `bash`, `python3`（標準ライブラリのみ・追加パッケージ不要）, `jq`, 任意のブラウザ
- 任意（ローカル lint 用）: [`shellcheck`](https://www.shellcheck.net/), [`ruff`](https://docs.astral.sh/ruff/)

## テスト / Tests
インストール〜記録〜配信〜アンインストールを、隔離した一時 HOME で一気通貫に検証します（実 `~/.claude` には触れません）:

```bash
bash test/smoke.sh
```

CI（`.github/workflows/ci.yml`）では次を回します:
- `shellcheck` + `bash -n`（全シェルスクリプト）
- `ruff` + `py_compile`（`bin/*.py`）
- smoke test を **ubuntu / macOS × direct / bootstrap(ワンライナー経路)** のマトリクスで

PR を出す前にローカルで smoke を green にしてください。

## コード規約 / Conventions
- シェルは **shellcheck クリーン**、Python は **ruff クリーン**に保つ。
- statusLine から得たレート制限値は**無加工で記録**する（`sampler.sh` は変換しない）のが原則。
- 表示ロジック（`bin/pace-json.py`）を変えるときは、既存の回帰テスト（**窓内リセット** / **stale スナップショット除外**）を壊さないこと。挙動を変える場合は smoke にケースを追加する。
- ユーザー設定（`config.json` / `biz-hours.json`）を壊さない・上書きしない（`install.sh` は冪等）。

## 変更の流れ / Workflow
1. Issue で相談（大きめの変更は事前に）／ or fork & branch
2. 変更 + `bash test/smoke.sh` が green + lint クリーン
3. PR。何を・なぜ、を簡潔に。スクショ/GIF があると助かります。

## good first issue 候補 / Ideas
- Homebrew tap（`brew install` 対応）
- `asciinema` によるインストール〜起動デモの追加
- `biz-hours.json` の値域バリデーション（`biz_start_hour < biz_end_hour`、0–24 など）
- ビューアのアクセシビリティ改善（色覚多様性への配慮・キーボード操作）

## ライセンス / License
コントリビュートは [MIT](LICENSE) の下で受け入れられます。
