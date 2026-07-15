#!/usr/bin/env bash
# claude-token-pace ワンライナー・インストーラ（curl -fsSL .../bootstrap.sh | bash）。
# リポジトリを一時ディレクトリに clone し、その中の install.sh を実行する。
#
# 環境変数:
#   TOKEN_PACE_REPO  clone 元 URL（既定: 公式リポジトリ）
#   TOKEN_PACE_REF   ブランチ/タグ（既定: main。例 v0.1.0 で固定版）
#   TOKEN_PACE_DIR   設置先（install.sh がそのまま尊重）
# 依存: git（clone 用）／python3・jq は install.sh が確認する。
set -euo pipefail

REPO_URL="${TOKEN_PACE_REPO:-https://github.com/k-tashiro-arent/claude-token-pace.git}"
REF="${TOKEN_PACE_REF:-main}"

if ! command -v git >/dev/null 2>&1; then
  echo "ERROR: 'git' が必要です（clone に使用）。git を入れてから再実行してください。" >&2
  exit 1
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/claude-token-pace.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

echo "claude-token-pace bootstrap: cloning $REPO_URL ($REF) ..."
if ! git clone --quiet --depth 1 --branch "$REF" "$REPO_URL" "$tmp/repo" 2>/dev/null; then
  # REF がタグ/ブランチでない場合（コミット SHA 等）。--branch は SHA を受け付けないため
  # 既定ブランチを full clone してから該当 REF を checkout する。checkout も失敗したら
  # 「見つからない ref」なので、既定ブランチのまま続行することを明示的に警告する。
  git clone --quiet "$REPO_URL" "$tmp/repo"
  if ! git -C "$tmp/repo" checkout --quiet "$REF" 2>/dev/null; then
    echo "WARNING: ref '$REF' が見つかりません。既定ブランチのまま install を続行します。" >&2
  fi
fi

if [[ ! -f "$tmp/repo/install.sh" ]]; then
  echo "ERROR: clone 先に install.sh がありません（URL/REF を確認してください）。" >&2
  exit 1
fi

bash "$tmp/repo/install.sh"
