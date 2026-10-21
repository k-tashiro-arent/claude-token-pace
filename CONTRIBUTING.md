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

記録の経路（定期実行・`bin/tick.sh`・`install.sh` / `uninstall.sh`）に触る変更をしたら、
実環境に反映したあと、記録が続いていることを確かめてください（読み取り専用で、何も変更しません）:

```bash
bash test/live-check.sh        # 0 = 動いている / 1 = 異常あり / 2 = 定期実行が未設置
```

smoke が通っても、実環境の定期実行が止まっていれば利用者には記録が届きません。

## コード規約 / Conventions
- シェルは **shellcheck クリーン**、Python は **ruff クリーン**に保つ。
- 使用量 API（`bin/usage-fetch.py`）から得たレート制限値は**無加工で記録**するのが原則。statusLine は記録のきっかけにだけ使い、statusLine に渡される値は記録しない（古いスナップショットが混ざるため）。
- 表示ロジック（`bin/pace-json.py`）を変えるときは、既存の回帰テスト（**窓内リセット** / **stale スナップショット除外**）を壊さないこと。挙動を変える場合は smoke にケースを追加する。
- ユーザー設定（`config.json` / `biz-hours.json`）を壊さない・上書きしない（`install.sh` は冪等）。

## 共有資源の扱い / Shared resources
**共有資源を変更・削除・停止する前に、それが自分の設置（`$TOKEN_PACE_DIR`）のものだと証明すること。
証明できないものには触らず、触らなかったことを出力に残す。**

- 対象: `systemctl --user`（enable / disable / start / stop / restart）、`crontab`、`loginctl`、
  `launchctl`、`kill`、`rm -rf`、他のプログラムの設定ファイル（`settings.json` など）。
- 証明のしかた: systemd はユニットの `ExecStart`、cron は該当行が、この設置先の `bin/tick.sh` を
  指していることを確かめる。PID は、それが自分の起動したプロセスであることを確かめる。
- **HOME を差し替えても隔離できない資源がある。** systemd の user manager と crontab は uid 単位、
  PID はホスト単位、macOS の Keychain はログインセッション単位で共有される。
  一時 HOME で動く試験からでも、これらへの操作は実ユーザーの環境に効く。
- `test/smoke.sh` は、試験の前後で実ユーザーの timer の状態・ユニットファイル・crontab が
  変わっていないことを検査し、変わっていれば失敗する。この検査を弱めたり外したりしない。

背景: 2026-10-20、試験から実行した `install.sh` の撤去処理が、所有を確かめずに
`systemctl --user disable --now` を呼び、実ユーザーの timer を止めた。smoke は通ったまま、
記録が 14.5 時間欠測した。

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
