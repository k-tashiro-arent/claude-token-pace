#!/usr/bin/env python3
"""pace.jsonl -> pace.json（ブラウザ用の処理済み系列）。標準ライブラリのみ・matplotlib/PNG 不要。

- 入力 : $TOKEN_PACE_DIR/pace.jsonl     (1行1サンプル。usage-fetch.py が API と statusLine の値を append)
         $TOKEN_PACE_DIR/credits.jsonl (月次クレジット枠。credits-fetch.py が append。任意)
- 出力 : $TOKEN_PACE_DIR/pace.json   (tmp -> os.replace でアトミック更新)
- 設定 : $TOKEN_PACE_DIR/biz-hours.json  (標準ペースの基準。無い/不正なら既定 月-金 9-18)

used% の単調化: レート枠はアカウント共有だが、各セッションは自分が最後に受けた API レスポンス
時点の used%/resets_at しか持たない。pace.jsonl には複数セッションが混在するため、
(1)対象窓の resets_at に一致する観測だけ採用し (2)running-max で包絡線化する。
target 窓は「最大 ts 行の resets_at」ではなく「観測された resets_at の最大値」で選ぶ
(max_reset)。idle/古いセッションが fresh な ts で古い resets_at を書いても窓が後退しない。
"""

import array
import json
import math
import os
import struct
import sys
from datetime import datetime, timezone

TP_DIR = os.path.expanduser(os.environ.get("TOKEN_PACE_DIR") or "~/.claude/token-pace")
LOG = os.path.join(TP_DIR, "pace.jsonl")
CREDITS_LOG = os.path.join(TP_DIR, "credits.jsonl")
CODEX_LOG = os.path.join(TP_DIR, "codex.jsonl")
JSON_OUT = os.path.join(TP_DIR, "pace.json")
LOCK = os.path.join(TP_DIR, ".lock")
BIZ_CONFIG = os.path.join(TP_DIR, "biz-hours.json")

MAX_LINES = 20000      # ログ肥大時はこの行数までに prune
KEEP_LINES = 12000     # prune 後に残す行数

# 窓内リセット検出（稀に Anthropic 側が resets_at 据え置きのまま used% を下げる事象）。
# 直近 RESET_WINDOW 件の最大値が現包絡より RESET_DROP pt を超えて低ければ包絡を張り直す。
RESET_DROP = 5.0
RESET_WINDOW = 5

JST_OFFSET = 9 * 3600  # JST=UTC+9 固定(DST無)
FIVE_HOUR = 5 * 3600
SEVEN_DAY = 7 * 86400
PLAYBACK_SPAN = 7 * 86400   # プレイバック(早送り再生)で遡る既定の長さ=7d
HISTORY_SPAN = 30 * 86400       # Align モード（全パネル共通軸）で「表示する」窓の幅=1か月
HISTORY_DATA_SPAN = 60 * 86400  # 履歴として「持たせる」長さ=2か月。再生では 30 日幅の窓が
                                # 60 日前から現在まで滑るので、表示幅の倍のデータが要る。
                                # どちらも、全ログを通じてより新しい記録しか無ければ最古まで。

# resets_at は同じ窓でも数秒ゆらぐ（実測: Codex は論理窓 31 個中 29 個・最大 15 秒。
# Claude は 55 日・5h 163 窓 / 7d 9 窓でゆらぎ 0）。この許容内の値は同一窓として扱う。
# 完全一致で絞ると窓が分裂し、最大値を現在窓に選んだ結果その窓の観測を
# ほとんど捨ててしまう。両側で同じ規則にする（Claude 側もゆらぎ得ることを前提にする）。
RESET_TOL = 60

# 予測（使用率の確率分布）の取り込み。別ツール claude-codex-router が窓ごとの分位を書く。
# 置き場所は router 自身のデータディレクトリ（各ツールは自分のディレクトリにだけ書く）。
# router の既定の置き場は ~/.claude-codex-router（以前は ~/.claude/codex-router）。
# FORECAST_JSON で明示指定もできる。ファイルが無ければ帯を出さないだけで、他の表示は変わらない。
FORECAST_JSON = os.path.expanduser(
    os.environ.get("FORECAST_JSON")
    or os.path.join(os.environ.get("CLAUDE_CODEX_ROUTER_DIR") or "~/.claude-codex-router",
                    "data", "forecast.json"))
FORECAST_RESET_TOL = 120   # 予測の窓とパネルを突き合わせる許容差（秒。実測の差は 0〜3 秒）
# 予測は標本そのもの（窓ごとに ts[] と paths[][]）で届く。描く分位はこちらで切り出す。
FORECAST_LEVELS = tuple(round(0.05 * k, 2) for k in range(1, 20))   # 5% 刻み 19 段階
# 予測が今の状態に合っているかは、相手の更新間隔ではなく起点のずれだけで見る。
# 超えても捨てない。帯の描き方を変えて（黄色・薄く）古いことを示す。消すと理由が伝わらない。
FORECAST_U_TOL = 5.0       # 起点 u と今の used% の差（ポイント）

# 再生（早送り）中にも帯を出すため、分位を 15 分格子で追記して PLAYBACK_SPAN ぶん持つ。
# 予測が付いているパネルはすべて書く（枠をこちらで選ばない）。枠の構成は
# Codex 側の都合で変わるので、固定の一覧を持つと新しい枠が黙って落ちる。
# ビューアの再生カーソルも同じ格子に乗るので、帯の起点とカーソルが必ず一致する。
# 形式は uint16 の時間方向差分（分位は時間方向に単調なので差分は 0 以上。
# 実測 215 万組で減少 0）。実測で 7 日・2 枠が 2.4 MB、gzip 後 0.53 MB。
# 同じものを JSON で並べると 7.3 MB・1.6 MB になる。
FC_HIST_OUT = os.path.join(TP_DIR, "forecast-hist.bin")
FC_HIST_SLOT = 900             # 追記の格子（秒）。ビューアの PB_SLOT と揃える
FC_HIST_MAGIC = b"TPFC"
FC_HIST_VER = 2                # 2: 枠を番号ではなくパネルのキーで持つ（枠を固定しないため）
FC_HIST_HEAD = "<IHIIHH"       # slot / キーの長さ / 終端時刻 / 刻み×100 / ステップ数 / 起点×10
FC_HIST_HEAD_SZ = struct.calcsize(FC_HIST_HEAD)


def load_biz_config():
    """biz-hours.json から就業時間を読む。無い/不正なら既定(月-金 9-18)。"""
    days, start, end = {1, 2, 3, 4, 5}, 9, 18
    try:
        with open(BIZ_CONFIG, encoding="utf-8") as f:
            cfg = json.load(f)
        d = cfg.get("biz_days")
        if isinstance(d, list) and d:
            days = {int(x) for x in d}
        s = cfg.get("biz_start_hour")
        if isinstance(s, (int, float)) and not isinstance(s, bool):
            start = s
        e = cfg.get("biz_end_hour")
        if isinstance(e, (int, float)) and not isinstance(e, bool):
            end = e
    except Exception:
        pass
    return days, start, end


BIZ_DAYS, BIZ_START_HOUR, BIZ_END_HOUR = load_biz_config()


def read_jsonl(path):
    rows = []
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    continue  # 追記途中の壊れ行はスキップ
    except FileNotFoundError:
        return []
    return rows


def read_rows():
    return read_jsonl(LOG)


def prune_if_needed(total):
    """行数が上限を超えたら、flock 下で末尾 KEEP_LINES 行に切り詰める。"""
    if total <= MAX_LINES:
        return
    try:
        import fcntl
        with open(LOCK, "w") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            with open(LOG, "r", encoding="utf-8") as f:
                lines = f.readlines()
            if len(lines) > MAX_LINES:
                tail = lines[-KEEP_LINES:]
                tmp = LOG + ".tmp"
                with open(tmp, "w", encoding="utf-8") as f:
                    f.writelines(tail)
                os.replace(tmp, LOG)
    except Exception:
        pass


def max_reset(rows, key):
    """観測された resets_at の最大値を返す。resets_at は窓が進むほど増える一方なので
    最大値＝現在(最新)窓。最大 ts 行の値ではなく最大 resets_at を採ることで、idle/古い
    セッションが fresh な ts で古い resets_at を書いても target window が後退しない。"""
    best = None
    for r in rows:
        v = r.get(key)
        if v is None:
            continue
        try:
            v = float(v)
        except (ValueError, TypeError):
            continue
        if best is None or v > best:
            best = v
    return best


def envelope(seq):
    """used% の包絡線。基本は running-max（単調非減少化）で、複数セッションの遅延・
    低値観測が線を下げるのを防ぐ。ただし「窓内リセット」（稀に Anthropic 側が resets_at
    据え置きのまま used% を大きく下げる事象）を検出したら、その位置で包絡を張り直す。

    リセット判定: 直近 RESET_WINDOW 件の最大値が現包絡 m より RESET_DROP pt を超えて
    低い＝どのセッションももう高値を報告していない、とみなす。遅延した単発の低値(stale)は
    直近に fresh な高値が残るため recent_max が下がらず、誤検出しない。
    """
    out, m = [], None
    for i, v in enumerate(seq):
        if m is None or v > m:
            m = v
        elif m - v > RESET_DROP and i + 1 >= RESET_WINDOW:
            recent_max = max(seq[i - RESET_WINDOW + 1:i + 1])
            if m - recent_max > RESET_DROP:
                m = recent_max   # 窓内リセット → ここから包絡を張り直す
        out.append(m)
    return out


def mark_old_window(rows):
    """h5r が後退した行に「古い窓のスナップショット」の印を付ける（ts 昇順の前提）。

    5h のリセット時刻は前へ進むだけなので、いったん観測した h5r より古い h5r を報告する
    行は、別の（古い）窓のスナップショットである。観測時点より h5r が未来なので _stale
    では弾けない。実測: 2026-10-20 12:51:43 の 1 行が h5=0 / d7=100・h5r は現窓より
    2 時間 20 分前 を報告し、前後が d7=5〜10 のところで 7d が 100% へ跳ねた。
    """
    seen = None
    for r in rows:
        v = r.get("h5r")
        if v is None:
            continue
        try:
            v = float(v)
        except (ValueError, TypeError):
            continue
        if seen is not None and v < seen - RESET_TOL:
            r["_old_window"] = True      # 以降の判定は _stale に集約する
        elif seen is None or v > seen:
            seen = v


def _stale(r, ts, strict=False):
    """観測時点で既に過ぎた 5h リセットを持つ行＝古いスナップショット。

    あわせて、mark_old_window が付けた「h5r が後退した行」の印もここで見る。

    新鮮な観測は必ず「5h リセット(h5r) が観測時点より未来」。セッション再開直後などに
    statusLine が過去の rate_limits スナップショットを出すことがあり、7d は窓が長いため
    resets_at が現窓と一致してしまう。これを弾かないとスパイクになる。

    h5r が無い行は鮮度を確認できない。strict なら捨てる。実測: 10,295 行中 32 行が
    h5r=null で、そのすべてが h5 も null（statusLine に five_hour ブロックが無い応答）。
    そのうち 1 行が前後の正常値 2% に対して d7=100 を報告しており、包絡の running-max が
    100 へ跳ね返って「100→0→100」の異常な形になっていた。
    """
    if r.get("_old_window"):     # mark_old_window が付けた印（h5r が後退した行）
        return True
    v = r.get("h5r")
    if v is None:
        return strict
    try:
        return float(v) <= ts
    except (ValueError, TypeError):
        return False


def _strict_stale(rows):
    """h5r を持つ行が 1 つでもあれば、h5r 欠落行は「確認できない」として捨ててよい。

    5h 枠が無いプラン（h5r が常に null）では捨てると 7d が空になるので、その場合は
    従来どおり残す。実測では h5r=null が 3 行以上連続することはなかった。
    """
    return any(r.get("h5r") is not None for r in rows)


def even_at(reset, ts, win_len, xmode):
    """窓 [reset-win_len, reset] の中で ts 時点の標準ペース%。live パネルと同じ定義。"""
    w1 = reset - win_len
    if xmode == "time":          # 1 日以内の窓は均等直線
        return max(0.0, min(100.0, (ts - w1) / win_len * 100.0)) if win_len > 0 else 0.0
    tot = bizsec(w1, reset)      # 長い窓は就業時間の階段
    return max(0.0, min(100.0, bizsec(w1, ts) / tot * 100.0)) if tot > 0 else 0.0


def history_series(rows, val_key, reset_key, lo_epoch, hi_epoch,
                   tol=0.0, use_stale_filter=False, use_envelope=True, even_fn=None):
    """[lo_epoch, hi_epoch] の全観測を「窓ごとに」処理して時刻順に連結する（Align 用）。

    現在窓だけを描く window_series と違い、過去の窓も含めるので窓の境界で値が
    0 付近に戻る鋸歯になる。**envelope は窓ごとに掛ける**。30 日を通しで
    running-max すると、どの窓のピークも引きずって 100% の平線になってしまう。

    窓の区切りは resets_at。Codex は同一窓でも数秒ゆらぐので tol>0 でバケット化する。
    連続する同一窓をひとかたまりとして扱うので、描画時に x が前後しない。

    even_fn(reset, ts) を渡すと各点に標準ペース%を 3 要素目として付ける。Align モードでも
    通常モードと同じ色（pace 乖離）で描くために使う（even の線自体は描かない）。
    """
    strict = _strict_stale(rows) if use_stale_filter else False
    pts = []
    for r in rows:
        ts, v, rk = r.get("ts"), r.get(val_key), r.get(reset_key)
        if ts is None or v is None or rk is None:
            continue
        try:
            ts, v, rk = float(ts), float(v), float(rk)
        except (ValueError, TypeError):
            continue
        if ts < lo_epoch or ts > hi_epoch:
            continue
        if use_stale_filter and _stale(r, ts, strict):
            continue
        pts.append((ts, v, rk))
    if not pts:
        return []

    if tol > 0:                       # ゆらぐ resets_at を論理窓へ畳む
        index = {}
        for gi, g in enumerate(_reset_buckets({p[2] for p in pts}, tol)):
            for v in g:
                index[v] = gi
        win_of = index.get
    else:
        def win_of(rk):
            return rk

    pts.sort(key=lambda p: p[0])
    out, cur, buf, newest = [], None, [], None

    def flush():
        if not buf:
            return
        ys = envelope([y for _, y, _ in buf]) if use_envelope else [y for _, y, _ in buf]
        reset = max(r for _, _, r in buf)      # この窓の resets_at（ゆらぎは最大値で代表）
        seq = [[t, y] for (t, _, _), y in zip(buf, ys)]
        seq = compress_steps(seq)
        if even_fn is not None:
            seq = [[t, y, round(even_fn(reset, t), 1)] for t, y in seq]
        out.extend(seq)

    for ts, v, rk in pts:
        w = win_of(rk)
        # 窓は前に進む一方。既に次の窓を見たあとで古い窓を報告する行は、その
        # セッションが持っていた古いスナップショット（実測: 08/19 15:00 の 7d
        # リセット直後、別セッションが 1 分後に前の窓の 98% を報告し、履歴が
        # 0→98→0 と跳ねていた）。現在窓だけを描く window_series では resets_at
        # 一致で弾かれるが、全窓を並べる履歴では弾かれないのでここで落とす。
        if newest is not None and w < newest:
            continue
        newest = w if newest is None or w > newest else newest
        if cur is not None and w != cur:
            flush()
            buf.clear()
        cur = w
        buf.append((ts, v, rk))
    flush()
    return out


def window_series(rows, val_key, reset_key, target_reset, lo_epoch, hi_epoch):
    """対象窓の観測だけを取り出し、時刻昇順・envelope した (xs, ys) を返す。

    - target_reset から RESET_TOL 以内の resets_at の観測のみ採用（別窓の遅延観測を除外）。
    - stale スナップショット除外: 新鮮な観測は必ず「5h リセット(h5r) が観測時点より未来」。
      h5r <= ts の行は、セッション再開直後などに statusLine が出した過去の rate_limits
      スナップショット（別=過去の 5h 窓の値）なので捨てる。7d 窓は 7 日長のため古い
      スナップショットでも d7r が現窓と一致してしまい、これを弾かないとスパイクになる。
    """
    strict = _strict_stale(rows)
    pts = []
    for r in rows:
        ts, v, rk = r.get("ts"), r.get(val_key), r.get(reset_key)
        if ts is None or v is None:
            continue
        try:
            ts, v = float(ts), float(v)
        except (ValueError, TypeError):
            continue
        if ts < lo_epoch or ts > hi_epoch:
            continue
        if _stale(r, ts, strict):   # 古いスナップショット（判定は _stale に集約）
            continue
        if target_reset is not None and rk is not None:
            try:
                if abs(float(rk) - target_reset) > RESET_TOL:
                    continue
            except (ValueError, TypeError):
                pass
        pts.append((ts, v))
    pts.sort(key=lambda x: x[0])
    if not pts:
        return [], []
    xs = [datetime.fromtimestamp(t) for t, _ in pts]
    ys = envelope([v for _, v in pts])
    return xs, ys


def bizsec(t0, t1):
    """[t0, t1] に含まれる就業秒。"""
    if t1 <= t0:
        return 0.0
    d0 = math.floor((t0 + JST_OFFSET) / 86400)
    d1 = math.floor((t1 + JST_OFFSET) / 86400)
    acc = 0.0
    for d in range(d0, d1 + 1):
        w = (d + 4) % 7            # epoch 日0=木
        iso = 7 if w == 0 else w   # 1=月 .. 7=日
        if iso in BIZ_DAYS:
            mid = d * 86400 - JST_OFFSET       # その日の JST 00:00 epoch
            bs = mid + BIZ_START_HOUR * 3600
            be = mid + BIZ_END_HOUR * 3600
            ov = min(t1, be) - max(t0, bs)
            if ov > 0:
                acc += ov
    return acc


def biz_baseline(win_start, win_end, step=600):
    """標準ペース: 窓内の就業時間の累積で 0→100%(階段状)。(xs, ys) を返す。

    分母は「窓の実就業秒」。7d 窓は 168h＝ちょうど 1 週間周期なので、開始位置に関わらず
    週の総就業秒に一致する（＝従来の定数分母と完全に同値）。月次のような可変長窓では
    窓ごとの正しい分母になる（定数のままだと 1 週間ぶんで 100% に張り付く）。
    """
    total = bizsec(win_start, win_end)
    if total <= 0:
        return [], []
    xs, ys = [], []
    t = win_start
    while t <= win_end:
        y = bizsec(win_start, t) / total * 100.0
        xs.append(datetime.fromtimestamp(t))
        ys.append(min(100.0, max(0.0, y)))
        t += step
    return xs, ys


def latest_ts(rows):
    """最新サンプルの ts（データのバージョン。generated_at に使う）。無ければ None。"""
    best = None
    for r in rows:
        ts = r.get("ts")
        try:
            ts = float(ts)
        except (ValueError, TypeError):
            continue
        if best is None or ts > best:
            best = ts
    return best


def _label(epoch, mode):
    dt = datetime.fromtimestamp(epoch)
    return dt.strftime("%m/%d %H:%M") if mode == "date" else dt.strftime("%H:%M")


def build_panels(rows, now_epoch, reset5_epoch, reset7_epoch):
    """5h/7d 各パネルの処理済み系列（epoch 基準）を dict のリストで返す。"""
    panels = []

    # ---- 5h ----
    if reset5_epoch is not None:
        w5, r5 = reset5_epoch - FIVE_HOUR, reset5_epoch
    else:
        r5, w5 = now_epoch, now_epoch - FIVE_HOUR
    xs, ys = window_series(rows, "h5", "h5r", reset5_epoch, w5,
                           reset5_epoch or (w5 + FIVE_HOUR))
    used = _used_series(xs, ys)
    even = [[w5, 0.0], [r5, 100.0]] if reset5_epoch is not None else []
    std5 = max(0.0, min(100.0, (now_epoch - w5) / FIVE_HOUR * 100.0))
    panels.append({
        "key": "5h", "xmode": "time",
        "x0": w5, "x1": r5, "reset_label": _label(r5, "time"),
        "used": used, "even": even,
        "used_now": (ys[-1] if ys else None), "std_now": std5,
    })

    # ---- 7d ----
    if reset7_epoch is not None:
        w7, r7 = reset7_epoch - SEVEN_DAY, reset7_epoch
    else:
        r7, w7 = now_epoch, now_epoch - SEVEN_DAY
    xs, ys = window_series(rows, "d7", "d7r", reset7_epoch, w7,
                           reset7_epoch or (w7 + SEVEN_DAY))
    used = _used_series(xs, ys)
    if reset7_epoch is not None:
        bx, by = biz_baseline(w7, reset7_epoch)
        even = [[x.timestamp(), y] for x, y in zip(bx, by)]
    else:
        even = []
    biz_total = bizsec(w7, r7)   # 7d 窓では週の総就業秒に一致（biz_baseline と同じ分母）
    std7 = max(0.0, min(100.0, bizsec(w7, now_epoch) / biz_total * 100.0)) if biz_total else 0.0
    panels.append({
        "key": "7d", "xmode": "date",
        "x0": w7, "x1": r7, "reset_label": _label(r7, "date"),
        "used": used, "even": even,
        "used_now": (ys[-1] if ys else None), "std_now": std7,
    })

    return panels


def month_bounds(epoch):
    """epoch を含む月の [1日00:00, 翌月1日00:00)(UTC) を返す。

    月次クレジット枠のリセットは UTC の月初。ローカル月初ではない（実測:
    2026-08-31 23:40:08 UTC に used=$1000.19 → 2026-09-01 00:05:16 UTC に $0.00。
    ローカル月初の 2026-09-01 00:00 JST を 8 時間 40 分過ぎた時点では未リセットだった）。
    API に月次枠の resets_at は無いため、境界はこの実測に基づく。
    """
    d = datetime.fromtimestamp(epoch, timezone.utc)
    y, m = (d.year + 1, 1) if d.month == 12 else (d.year, d.month + 1)
    return (datetime(d.year, d.month, 1, tzinfo=timezone.utc).timestamp(),
            datetime(y, m, 1, tzinfo=timezone.utc).timestamp())


def compress_steps(pts):
    """同値が続く区間を両端だけ残して間引く（階段の形は保つ）。

    クレジットはプラン枠を超えている間しか増えないため、大半の行は前後と同値になる。
    値が変わる点とその直前・直後を残すので、間引き後も系列の形状は変わらない。
    """
    n = len(pts)
    if n <= 2:
        return list(pts)
    out = [pts[0]]
    for i in range(1, n - 1):
        if pts[i][1] != pts[i - 1][1] or pts[i][1] != pts[i + 1][1]:
            out.append(pts[i])
    out.append(pts[-1])
    return out


def _used_series(xs, ys):
    """window_series の出力をパネルの used 形式にする。同値が続く区間は間引く。

    使用率は整数で包絡済みなので、大半の点は前後と同値になる。階段の形は変わらず、
    実測で 7d が 779 点 → 58 点、Codex が 497 点 → 12 点になる（pace.json は 5 秒ごとに配信される）。
    履歴（history_series）と月次パネルは元から間引いているので、それに揃える。
    """
    return [[t, y] for t, y in compress_steps([(x.timestamp(), y) for x, y in zip(xs, ys)])]


def build_month_panel(crows, now_epoch):
    """月次クレジット枠（extra usage）のパネル。credits.jsonl が無ければ None。

    枠が無効（extra_usage.is_enabled=false）な期間は出さない。無い予算を表示すると
    「使い切ってよい枠がある」と誤読されるうえ、残存した monthly_limit に対する
    used% は意味を持たないため。

    100% = monthly_limit（＝支出上限）。5h/7d と違い「使い切ってよい枠」ではないので、
    even ペース（満額基準）に対して灰色＝上限を使い切る軌道である点に注意。

    5h/7d と違い envelope（running-max）は掛けない。複数セッションが書く pace.jsonl と
    違って credits.jsonl は単一の取得器が書くので stale 混在が起きず、月替わりで値が
    0 に戻る系列に running-max を掛けると誤って前月のピークを引きずるため。
    """
    if not crows:
        return None
    target = max_reset(crows, "m1r")     # 観測された最大の m1r＝現在の月次窓
    if target is None:
        return None
    w1 = month_bounds(target - 1)[0]     # m1r は翌月1日00:00 なので 1 秒引いて当月に落とす
    r1 = target

    # 枠そのものが無効ならパネルを出さない。credits-fetch が API の
    # extra_usage.is_enabled を "en" として記録する。枠が無効でも monthly_limit に前の
    # 値が残ることがあるため、金額ではなくこのフラグで判定する（実測: limit は全行で正）。
    # "en" を持たない古い行は判定に使わない（記録前の履歴を消さないため）。
    latest_en, latest_en_ts = None, None
    for r in crows:
        en = r.get("en")
        if not isinstance(en, bool):
            continue
        try:
            ts = float(r.get("ts"))
        except (ValueError, TypeError):
            continue
        if ts < w1 or ts > r1:
            continue                     # 当月の観測だけを見る
        if latest_en_ts is None or ts > latest_en_ts:
            latest_en_ts, latest_en = ts, en
    if latest_en is False:
        return None

    pts = []
    for r in crows:
        ts, used, limit = r.get("ts"), r.get("used"), r.get("limit")
        if ts is None or used is None or limit is None:
            continue
        try:
            ts, used, limit = float(ts), float(used), float(limit)
        except (ValueError, TypeError):
            continue
        if limit <= 0:
            continue     # 枠未割当（monthly_limit=0）は % を定義できない
        m1r = r.get("m1r")
        if m1r is not None:
            try:
                if float(m1r) != target:
                    continue     # 別の月の観測
            except (ValueError, TypeError):
                pass
        if ts < w1 or ts > r1:
            continue
        pts.append((ts, max(0.0, min(100.0, used / limit * 100.0))))
    pts.sort(key=lambda x: x[0])
    if not pts:
        return None
    used = [[t, y] for t, y in compress_steps(pts)]

    bx, by = biz_baseline(w1, r1, step=1800)   # 月は長いので 30 分刻み（点数を抑える）
    even = [[x.timestamp(), y] for x, y in zip(bx, by)]
    denom = bizsec(w1, r1)
    std1 = max(0.0, min(100.0, bizsec(w1, now_epoch) / denom * 100.0)) if denom > 0 else 0.0
    return {
        "key": "1mo", "xmode": "date",
        "x0": w1, "x1": r1, "reset_label": _label(r1, "date"),
        "used": used, "even": even,
        "used_now": used[-1][1], "std_now": std1,
    }


def _win_label(minutes):
    """窓の長さ(分)を 5h / 7d のような短いラベルにする。"""
    m = int(minutes)
    if m % 1440 == 0:
        return f"{m // 1440}d"
    if m % 60 == 0:
        return f"{m // 60}h"
    return f"{m}m"


def _reset_buckets(values, tol=RESET_TOL):
    """近接する resets_at を論理窓ごとにまとめる（昇順のグループ列を返す）。"""
    groups = []
    for v in sorted(values):
        if groups and v - groups[-1][-1] <= tol:
            groups[-1].append(v)
        else:
            groups.append([v])
    return groups


def _codex_even(w1, r1, step=None):
    """Codex の枠の標準ペース線と xmode。窓の長さで規則が変わるのでパネルと再生で共有する。

    step を渡すと階段の刻みを粗くできる。再生は窓を何枚も持つので、
    線の点数が pace.json の大きさにそのまま足し上がる。
    """
    if r1 - w1 <= 86400:                    # 1 日以内の窓は 5h と同じく均等直線
        return [[w1, 0.0], [r1, 100.0]], "time"
    bx, by = biz_baseline(w1, r1, step=step or (1800 if r1 - w1 > SEVEN_DAY else 600))
    return [[x.timestamp(), y] for x, y in zip(bx, by)], "date"   # 長い窓は就業時間の階段


def _codex_panel(rows, ukey, wkey, rkey, now_epoch):
    """Codex の 1 枠ぶんのパネル。該当データが無ければ None。

    窓の長さは定数ではなく観測値(window_minutes)から決める。Codex は 5h+7d の
    2 枠だったり 7d の 1 枠だったりするため、枠の構成が変わっても追従できる。
    used% は Claude 側と同様に包絡線化する（並行セッションの古い観測が混ざり、
    同一 resets_at のまま数 pt 逆行する事象を実測している）。
    """
    # 現在窓は「最新の観測が属するバケット」で選ぶ。resets_at が最大のバケットでは
    # ない点に注意：枠の構成が変わると、同じ列に残る古い枠の resets_at のほうが
    # 未来にあることがある（実測: 08/26 に 7d → 5h+7d へ戻った際、primary 列に
    # 残る 7d の resets_at 09/01 が、現在の 5h の 08/26 20:09 より先だった。最大で
    # 選ぶと 21 時間前が最後の観測である古い 7d が現在窓になり、5h が消えた）。
    resets, latest_ts, latest_reset = set(), None, None
    for r in rows:
        try:
            v = float(r.get(rkey))
        except (ValueError, TypeError):
            continue
        resets.add(v)
        try:
            ts = float(r.get("ts"))
        except (ValueError, TypeError):
            continue
        if latest_ts is None or ts > latest_ts:
            latest_ts, latest_reset = ts, v
    if latest_reset is None:
        return None
    cur = next(b for b in _reset_buckets(resets) if b[0] <= latest_reset <= b[-1])
    lo, hi = cur[0], cur[-1]
    if hi <= now_epoch:
        # 最新の観測窓が既に終わっている＝この枠の現在値は分からない。
        # 枠の構成が変わって片方が消えた場合（Codex は 5h+7d → 7d に変わった実績が
        # ある）、古い窓をそのまま描くと現在の枠として誤読されるのでパネルを出さない。
        return None

    pts, seen, mins = [], set(), {}
    for r in rows:
        ts, u, v, w = r.get("ts"), r.get(ukey), r.get(rkey), r.get(wkey)
        if ts is None or u is None or v is None:
            continue
        try:
            ts, u, v = float(ts), float(u), float(v)
        except (ValueError, TypeError):
            continue
        if not (lo <= v <= hi):
            continue
        k = (ts, u, v)
        if k in seen:
            continue                        # 増分スキャン状態を失った際の重複を吸収
        seen.add(k)
        pts.append((ts, u))
        if w is not None:
            mins[w] = mins.get(w, 0) + 1
    if not pts or not mins:
        return None

    wm = max(mins.items(), key=lambda kv: kv[1])[0]   # 窓長は最頻値を採用
    r1 = hi
    w1 = r1 - float(wm) * 60
    pts.sort(key=lambda x: x[0])
    ys = envelope([y for _, y in pts])
    used = [[t, y] for t, y in compress_steps([(t, y) for (t, _), y in zip(pts, ys)])]

    even, xmode = _codex_even(w1, r1)
    if xmode == "time":
        span = r1 - w1
        std = max(0.0, min(100.0, (now_epoch - w1) / span * 100.0)) if span > 0 else 0.0
    else:
        denom = bizsec(w1, r1)
        std = max(0.0, min(100.0, bizsec(w1, now_epoch) / denom * 100.0)) if denom > 0 else 0.0

    return {
        "key": "codex " + _win_label(wm), "xmode": xmode,
        "x0": w1, "x1": r1, "reset_label": _label(r1, xmode),
        "used": used, "even": even,
        "used_now": used[-1][1], "std_now": std,
        # 履歴を同じ枠から引くための目印（窓長）。pace.json へ出す前に取り除く。
        "_win": wm,
    }


def build_codex_panels(rows, now_epoch):
    """codex.jsonl から primary / secondary のパネルを作る（無い枠は出さない）。"""
    panels = []
    for ukey, wkey, rkey in (("u", "w", "r"), ("u2", "w2", "r2")):
        p = _codex_panel(rows, ukey, wkey, rkey, now_epoch)
        if p is not None:
            panels.append(p)
    return panels


def _playback_segments(rows, start, now_epoch, key, val_key, reset_key, win_len, even_fn, xmode):
    """Claude 側（5h/7d）のセグメント列。観測を拾って共通の組み立てに渡すだけ。

    古いスナップショット（_stale）だけはここで弾く。Codex にはこの概念が無い。
    """
    strict = _strict_stale(rows)
    pts = []
    for r in rows:
        ts, v, rk = r.get("ts"), r.get(val_key), r.get(reset_key)
        if ts is None or v is None or rk is None:
            continue
        try:
            ts, v, rk = float(ts), float(v), float(rk)
        except (ValueError, TypeError):
            continue
        if _stale(r, ts, strict):
            continue
        pts.append((ts, v, rk))
    return _playback_from_points(pts, key, win_len, start, now_epoch,
                                 lambda w1, r1: (even_fn(w1, r1), xmode))


def _sliding_window(obs, win_len):
    """使用率 0% の間に resets_at が「今から 1 窓後」を返し続けてできた見かけの窓か。

    その窓の観測はすべて「リセット = 観測時刻 + 窓長」になり、窓が一向に進まない。
    観測数や期間の下限で落とすと、短い実セッションまで消える（実測: Claude 5h の
    163 窓中 7 窓が 30 分未満で、いずれも used > 0、最大 40%）ので、滑りの形そのもので判定する。
    実測: Codex 12 窓中 8 窓が該当（いずれも観測 1 点・used 0%）、Claude は 172 窓中 0。
    """
    return all(abs(r - ts - win_len) <= RESET_TOL for ts, _u, r in obs)


def _playback_from_points(pts, key, win_len, start, now_epoch, even_fn):
    """(時刻, 使用率, リセット) の列から窓ごとのセグメントを作る（Claude / Codex 共通）。

    窓は resets_at を RESET_TOL で束ねたバケット。used は包絡線にして、階段の形を
    保ったまま間引く。even_fn は (標準ペース線, xmode) を返す。
    最後に _clip_segments で次の窓の開始より前に切る。
    """
    segs = []
    for b in _reset_buckets({r for _ts, _u, r in pts}):
        r1, w1 = b[-1], b[-1] - win_len
        if not (r1 > start and w1 < now_epoch):      # 窓 [w1, r1] が [start, now] と重ならない
            continue
        obs = sorted(p for p in pts if b[0] <= p[2] <= b[-1] and w1 <= p[0] <= r1)
        if not obs or _sliding_window(obs, win_len):
            continue
        ys = envelope([u for _ts, u, _r in obs])
        used = [[t, y] for t, y in compress_steps([(o[0], y) for o, y in zip(obs, ys)])]
        even, xmode = even_fn(w1, r1)
        segs.append({"key": key, "x0": w1, "x1": r1, "xmode": xmode,
                     "reset_label": _label(r1, xmode), "even": even, "used": used})
    return _clip_segments(segs)


def _clip_segments(segs):
    """セグメントを開始順に並べ、各々の used を次の窓の開始より前に切る。

    Codex は収集経路が 2 つ（ログと app-server）あるため、窓が切り替わった後に数分だけ
    古い窓の読みが届く（実測: 10/15 15:13 に切り替わった後、前の窓に 15:15 の観測が 1 点）。
    残すとそのセグメントの末尾値（ヘッダの used）が、窓が終わった後の値になる。
    5h/7d は窓が順に並ぶのでこの切り詰めは何もしない。
    """
    segs = sorted(segs, key=lambda s: s["x0"])
    out = []
    for i, seg in enumerate(segs):
        if i + 1 < len(segs):
            nx = segs[i + 1]["x0"]
            seg["used"] = [u for u in seg["used"] if u[0] < nx]
        if seg["used"]:
            out.append(seg)
    return out


def _codex_playback_segments(xrows, start, now_epoch, win_min, key):
    """Codex の 1 枠ぶんのセグメント列。窓は観測された resets_at のバケットごと。

    Codex の枠は名目の窓長を待たずにサービス側でリセットされる（実測: 記録にある
    4 回の切り替わりはすべて名目の終わりまで 68.5 / 28.1 / 162.9 / 118.8 時間を残して起きている）。
    そのため名目の [リセット−窓長, リセット] は重なる。どの窓を見せるかはビューアが
    「開始済みのうち最も新しい窓」で選ぶ（pbSegAt）。

    使用率 0% の間は resets_at が「今から 1 窓後」を返し続けて数分ずつ滑るため、
    1 点だけの見かけの窓が並ぶ（実測: 10/13 08:24〜08:56 に 8 個）。履歴と同じ下限で落とす。
    """
    pts, seen = [], set()
    for r in xrows:
        for ukey, wkey, rkey in (("u", "w", "r"), ("u2", "w2", "r2")):
            ts, u, v, w = r.get("ts"), r.get(ukey), r.get(rkey), r.get(wkey)
            if ts is None or u is None or v is None or w is None:
                continue
            try:
                ts, u, v = float(ts), float(u), float(v)
                if int(w) != int(win_min):
                    continue
            except (ValueError, TypeError):
                continue
            k = (ts, u, v)
            if k in seen:
                continue           # 増分スキャン状態を失った際の重複を吸収
            seen.add(k)
            pts.append((ts, u, v))
    if not pts:
        return []
    return _playback_from_points(pts, key, float(win_min) * 60, start, now_epoch,
                                 lambda w1, r1: _codex_even(w1, r1, step=PLAYBACK_EVEN_STEP))


def build_playback(rows, xrows, now_epoch, codex_wins):
    """直近 PLAYBACK_SPAN(=7d) を早送り再生するためのセグメント列をパネルのキーごとに返す。

    - 期間: [max(now-7d, 最古サンプル), now]（履歴が 7d 未満なら最古サンプルから）。
    - この期間に重なる 5h 窓・7d 窓をそれぞれ古い順に列挙する。7d スパンでは 5h 窓は多数回、
      7d 窓も（now-7d が現 7d 窓の開始より前になるため）1 回リセット境界をまたぎ得る。
      ビューアは各パネルで再生カーソルが境界を越えるたびに窓を切り替える＝リセットが再現される。
    - Codex の枠は codex_wins（キー→窓長(分)）を受け取って同じように並べる。
      1mo はセグメントを作らない（窓が 1 か月で再生の 7 日間にリセットがほぼ入らず、
      ライブのパネルをカーソルで切り詰める今の振る舞いで正しいため）。
    - 履歴が短ければ各パネル 1 窓に縮退（リセット無し）。

    データが無い/どのパネルもセグメントが作れない場合は None。
    """
    earliest = None
    for r in rows:
        ts = r.get("ts")
        try:
            ts = float(ts)
        except (ValueError, TypeError):
            continue
        if earliest is None or ts < earliest:
            earliest = ts
    if earliest is None:
        return None
    start = max(now_epoch - PLAYBACK_SPAN, earliest)

    def biz_even(x0, x1):   # 窓を何枚も持つので、Codex と同じく粗い刻みで点数を抑える
        bx, by = biz_baseline(x0, x1, step=PLAYBACK_EVEN_STEP)
        return [[x.timestamp(), y] for x, y in zip(bx, by)]

    segs = {
        "5h": _playback_segments(rows, start, now_epoch, "5h", "h5", "h5r", FIVE_HOUR,
                                 lambda x0, x1: [[x0, 0.0], [x1, 100.0]], "time"),
        "7d": _playback_segments(rows, start, now_epoch, "7d", "d7", "d7r", SEVEN_DAY,
                                 biz_even, "date"),
    }
    for key, win_min in (codex_wins or {}).items():
        segs[key] = _codex_playback_segments(xrows, start, now_epoch, win_min, key)
    segs = {k: v for k, v in segs.items() if v}
    if not segs:
        return None
    return {"start": start, "now": now_epoch, "segs": segs}


def _month_hist_points(crows, lo_epoch, hi_epoch):
    """月次クレジットの履歴。値は used/limit の % で、月ごとに区切る。

    月次は単一の取得器が書くので stale 混在が起きず、月替わりで 0 に戻る系列に
    running-max を掛けると前月のピークを引きずるため envelope は掛けない。
    """
    pts = []
    for r in crows:
        ts, used, limit, m1r = r.get("ts"), r.get("used"), r.get("limit"), r.get("m1r")
        if ts is None or used is None or limit is None or m1r is None:
            continue
        try:
            ts, used, limit, m1r = float(ts), float(used), float(limit), float(m1r)
        except (ValueError, TypeError):
            continue
        if limit <= 0 or ts < lo_epoch or ts > hi_epoch:
            continue
        pts.append({"ts": ts, "v": max(0.0, min(100.0, used / limit * 100.0)), "m": m1r})
    def month_even(m1r, ts):
        w1 = month_bounds(m1r - 1)[0]
        tot = bizsec(w1, m1r)
        return max(0.0, min(100.0, bizsec(w1, ts) / tot * 100.0)) if tot > 0 else 0.0

    return history_series(pts, "v", "m", lo_epoch, hi_epoch, use_envelope=False,
                          even_fn=month_even)


def _codex_history(xrows, win_min, lo_epoch, hi_epoch):
    """指定した窓長(分)の観測を、primary/secondary のどちらの列にあっても拾う。

    Codex は枠の構成を変える（実測: 07/13 に 5h+7d → 7d、08/26 に 7d → 5h+7d）。
    同じ枠が列を移るため、列で追うと履歴が途切れたり別の枠が混ざったりする。
    """
    pts = []
    for r in xrows:
        for ukey, wkey, rkey in (("u", "w", "r"), ("u2", "w2", "r2")):
            w = r.get(wkey)
            if w is None:
                continue
            try:
                if int(w) != int(win_min):
                    continue
            except (ValueError, TypeError):
                continue
            u, rk, ts = r.get(ukey), r.get(rkey), r.get("ts")
            if u is not None and rk is not None and ts is not None:
                pts.append({"ts": ts, "v": u, "r": rk})
    win_len = float(win_min) * 60
    xmode = "time" if win_len <= 86400 else "date"
    return history_series(pts, "v", "r", lo_epoch, hi_epoch, tol=RESET_TOL,
                          even_fn=lambda r, t: even_at(r, t, win_len, xmode))


HISTORY_EVEN_STEP = 3600   # 履歴の標準ペース線の刻み（30 日を 1 時間刻みで十分な解像度）
PLAYBACK_EVEN_STEP = 1800  # 再生の窓の標準ペース線の刻み。窓を何枚も持つので点数を抑える
                           # （7 日の窓で 336 点。表示幅 600px なら 1 点 1.8px で階段の形は見分けない）
HISTORY_EVEN_MIN_OBS = 2      # これ未満の観測しかない窓は基準線を引かない
HISTORY_EVEN_MIN_SPAN = 1800  # 観測がこの秒数未満に収まる窓も同様（下記のスライド対策）


def window_spans(rows, reset_key, lo_epoch, hi_epoch, tol=0.0, sel=None):
    """[lo, hi] の観測を窓ごとにまとめ、(代表 reset, 最初の観測, 最後の観測) を昇順で返す。

    観測が極端に少ない窓は捨てる。Codex は使用率 0% のあいだ resets_at が
    「今から 1 窓後」を返し続けて秒単位でずれるため、1 点だけの見かけの窓が大量に
    できる（実測: 30 日で 24 バケット中 15 個が 1 点・used=0 のスライド痕）。
    """
    obs = {}
    for r in rows:
        ts = r.get("ts")
        if ts is None:
            continue
        try:
            ts = float(ts)
        except (ValueError, TypeError):
            continue
        if not (lo_epoch <= ts <= hi_epoch):
            continue
        for rk in (sel(r) if sel else ([r.get(reset_key)] if r.get(reset_key) is not None else [])):
            try:
                rk = float(rk)
            except (ValueError, TypeError):
                continue
            got = obs.get(rk)
            obs[rk] = (min(got[0], ts), max(got[1], ts), got[2] + 1) if got else (ts, ts, 1)
    if not obs:
        return []
    groups = _reset_buckets(set(obs), tol) if tol > 0 else [[v] for v in sorted(obs)]
    out = []
    for g in groups:
        t0 = min(obs[v][0] for v in g)
        t1 = max(obs[v][1] for v in g)
        n = sum(obs[v][2] for v in g)
        if n < HISTORY_EVEN_MIN_OBS or t1 - t0 < HISTORY_EVEN_MIN_SPAN:
            continue
        out.append((g[-1], t0, t1))
    out.sort(key=lambda q: q[1])
    return out


def _hist_even(spans, bounds_of, lo_epoch, hi_epoch):
    """窓ごとの標準ペースを「その窓が現在窓だった期間」にだけ描いて連結する。

    窓は重なることがある（実測: Codex の 7d は使用が再開するたびに張り直され、
    30 日で 9 窓のうち 7 組が前の窓と重なっていた）。単純に窓ぜんぶを描いて時刻順に
    並べると値が前後してしまうので、次の窓の観測が始まった時刻で切って重複させない。
    """
    out = []
    prev_end = lo_epoch
    for i, (rep, t0, _t1) in enumerate(spans):
        w1, r1 = bounds_of(rep)
        if r1 <= w1:
            continue
        start = max(w1, prev_end, lo_epoch)
        if i + 1 < len(spans):
            # 次の窓に切り替わる時刻。次の窓の観測が、その窓の開始より前から
            # 始まっていることがある（m1r をローカル月初で書いていた頃の行など）。
            # その場合に前の窓を早く切ってしまわないよう、次の窓の開始で下限を取る。
            nw1 = bounds_of(spans[i + 1][0])[0]
            nxt = max(spans[i + 1][1], nw1)
        else:
            nxt = hi_epoch
        end = min(r1, nxt, hi_epoch)
        if end <= start:
            continue
        span = r1 - w1
        t = start
        while t < end:
            out.append([t, round(even_at(r1, t, span, "date"), 1)])
            t += HISTORY_EVEN_STEP
        out.append([end, round(even_at(r1, end, span, "date"), 1)])
        prev_end = end
        del t0
    return out


def _codex_hist_even(xrows, win_min, lo_epoch, hi_epoch):
    """Codex の枠の標準ペース（履歴用）。1 日を超える窓だけ引く。

    5h のような短い窓は 30 日で 100 本以上になり読めないので出さない（live パネルで
    均等直線と就業時間の階段を分ける判定と同じ境界）。
    """
    win_len = float(win_min) * 60
    if win_len <= 86400:
        return []

    def sel(r):
        got = []
        for wkey, rkey in (("w", "r"), ("w2", "r2")):
            w, rk = r.get(wkey), r.get(rkey)
            if w is None or rk is None:
                continue
            try:
                if int(w) == int(win_min):
                    got.append(rk)
            except (ValueError, TypeError):
                continue
        return got

    spans = window_spans(xrows, None, lo_epoch, hi_epoch, tol=RESET_TOL, sel=sel)
    return _hist_even(spans, lambda rep: (rep - win_len, rep), lo_epoch, hi_epoch)


def attach_history(panels, rows, crows, xrows, now_epoch):
    """各パネルに hist（Align モードで共通軸に描く履歴系列）を付け、軸の左端を返す。

    データの左端は「現在の HISTORY_DATA_SPAN 前」（既定 60 日）。ただし全ログを通じて
    それより新しい記録しか無ければ、最古の記録時点まで（記録が無い区間を無駄に描かない）。
    表示はそのうち直近 HISTORY_SPAN（既定 30 日）だけで、残りは再生でのみ使う。
    軸は全パネル共通なので、ログごとに開始が違う場合は早く始まるログに合わせ、
    まだ記録の無いパネルはその区間が空になる。
    """
    oldest = None
    for src in (rows, crows, xrows):
        for r in src:
            ts = r.get("ts")
            if ts is None:
                continue
            try:
                ts = float(ts)
            except (ValueError, TypeError):
                continue
            if oldest is None or ts < oldest:
                oldest = ts
    if oldest is None:
        return None
    lo = max(now_epoch - HISTORY_DATA_SPAN, oldest)

    hist = {
        "5h": history_series(rows, "h5", "h5r", lo, now_epoch, tol=RESET_TOL,
                             use_stale_filter=True,
                             even_fn=lambda r, t: even_at(r, t, FIVE_HOUR, "time")),
        "7d": history_series(rows, "d7", "d7r", lo, now_epoch, tol=RESET_TOL,
                             use_stale_filter=True,
                             even_fn=lambda r, t: even_at(r, t, SEVEN_DAY, "date")),
        "1mo": _month_hist_points(crows, lo, now_epoch),
    }
    even_hist = {
        "7d": _hist_even(window_spans(rows, "d7r", lo, now_epoch, tol=RESET_TOL),
                         lambda rep: (rep - SEVEN_DAY, rep), lo, now_epoch),
        "1mo": _hist_even(window_spans(crows, "m1r", lo, now_epoch, tol=RESET_TOL),
                          lambda rep: month_bounds(rep - 1), lo, now_epoch),
    }
    for p in panels:
        win = p.pop("_win", None)
        if win is not None:
            p["hist"] = _codex_history(xrows, win, lo, now_epoch)
            got = _codex_hist_even(xrows, win, lo, now_epoch)
        else:
            p["hist"] = hist.get(p["key"], [])
            got = even_hist.get(p["key"])
        if got:
            p["hist_even"] = got
    return lo


def _panel_rank(p):
    """パネルの新しさ。最後の観測時刻を優先し、同じなら窓の終了が遅い方を新しいとみなす。"""
    used = p.get("used") or []
    last = used[-1][0] if used else float("-inf")
    x1 = p.get("x1")
    return (last, x1 if x1 is not None else float("-inf"))


def dedupe_panels(panels):
    """同じキーの枠が複数できたら、最新の 1 枚だけ残す（並び順は最初に出た位置を保つ）。

    Codex は枠の構成が変わることがあり、古い列に最後の観測が残ったままになる。実測:
    2026-09-30 16:41 に 5h+7d → 7d へ変わり、7d が secondary 列から primary 列へ移った。
    取り残された secondary 列の窓は終了が 2 日先だったため _codex_panel の「終了済み窓」
    ガード（hi <= now）では落ちず、同じ "codex 7d" が 2 枚できた（used 8% と 81%）。
    窓の終わりだけでは古い枠を落とせないので、最後に観測された＝今も更新されている方を採る。
    """
    best, order = {}, []
    for p in panels:
        k = p.get("key")
        if k not in best:
            order.append(k)
            best[k] = p
        elif _panel_rank(p) > _panel_rank(best[k]):
            best[k] = p
    return [best[k] for k in order]


def read_forecast(path=None):
    """router が書いた予測を読む。無い・壊れている・形が違えば {}（帯を出さないだけ）。

    出力仕様は相手の都合で変わり得るので、少しでも形が違えば黙って捨てる。ここで例外を
    上げると pace.json 全体が出なくなり、予測と関係のない表示まで止まるため。
    """
    target = FORECAST_JSON if path is None else path
    try:
        with open(target, encoding="utf-8") as f:
            d = json.load(f)
    except (OSError, ValueError):
        return {}
    return d if isinstance(d, dict) and isinstance(d.get("windows"), dict) else {}


def _quantile(col, q):
    """昇順の列から分位を 1 つ拾う（順序統計。router の取り方に合わせる）。"""
    return col[min(max(math.ceil(q * len(col)) - 1, 0), len(col) - 1)]


def _fc_points(w):
    """予測の 1 窓（ts[] と paths[][]）を [[ts, 分位…], …] に直す。

    paths は標本そのもので、ステップごとの並べ替えはされていない。分位はここで切り出す。
    値は上限 100 で打ち切る（使用率は上限を超えない）。打ち切りは単調なので、
    並べ替えの後に当てても分位は変わらない。
    長さの合わない標本は捨てる。残りが無い・2 点未満なら帯にならないので None。
    """
    ts, paths = w.get("ts"), w.get("paths")
    if not isinstance(ts, list) or len(ts) < 2 or not isinstance(paths, list) or not paths:
        return None, None
    try:
        tsf = [float(v) for v in ts]
        good = [[float(v) for v in pa] for pa in paths
                if isinstance(pa, list) and len(pa) == len(ts)]
    except (TypeError, ValueError):
        return None, None
    if not good:
        return None, None
    pts = []
    for j, tj in enumerate(tsf):
        col = sorted(min(pa[j], 100.0) for pa in good)
        pts.append([tj] + [round(_quantile(col, q), 2) for q in FORECAST_LEVELS])
    return list(FORECAST_LEVELS), pts


def _fc_p_full(w):
    """リセット時に上限へ達している標本の割合。出せなければ None。"""
    paths = w.get("paths")
    if not isinstance(paths, list) or not paths:
        return None
    last = []
    for pa in paths:
        if isinstance(pa, list) and pa:
            try:
                last.append(float(pa[-1]))
            except (TypeError, ValueError):
                return None
    return round(sum(1 for v in last if v >= 100.0) / len(last), 4) if last else None


def attach_forecast(panels, now_epoch, data=None):
    """対応する窓の予測を各パネルに fc として付ける。対応が無いパネルは触らない。

    突き合わせは「側（Claude/Codex）＋リセット時刻」で行う。予測側の窓の名前
    （claude-session / codex-7d など）は相手の都合で変わり得るのに対し、同じ窓なら
    リセット時刻は一致するため（実測の差は 0〜3 秒）。側はパネルのキーから決める。
    月次クレジット枠（1mo）に対応する窓は予測側に無いので、何も付かない。

    予測が今に合っているかは起点のずれ 1 本で見る。経過時間でも別に判定していたが、
    実測では経過の許容ちょうどの時点で既に起点が許容を超えている割合が 7d で 6〜8 割あり、
    二重になっていた。合っていなくても捨てず、fc.stale を立てて描き方で示す。
    """
    data = read_forecast() if data is None else data
    wins = data.get("windows") if isinstance(data, dict) else None
    if not isinstance(wins, dict):
        return
    try:
        t0 = int(float(data["t"]))
    except (KeyError, TypeError, ValueError):
        t0 = None
    for p in panels:
        x1 = p.get("x1")
        if x1 is None:
            continue
        side = "codex" if str(p.get("key") or "").startswith("codex") else "claude"
        for w in wins.values():
            if not isinstance(w, dict) or w.get("side") != side:
                continue
            try:
                if abs(float(w["r"]) - x1) > FORECAST_RESET_TOL:
                    continue
            except (KeyError, TypeError, ValueError):
                continue
            levels, pts = _fc_points(w)
            if not pts:
                continue
            stale = False                              # 起点が今の実績から離れていれば「古い」
            u, un = w.get("u"), p.get("used_now")
            if u is not None and un is not None:
                try:
                    stale = abs(float(u) - float(un)) > FORECAST_U_TOL
                except (TypeError, ValueError):
                    stale = False
            p["fc"] = {"t": t0, "levels": levels, "pts": pts,
                       "p_full": _fc_p_full(w), "stale": stale}
            break


def _fch_header():
    """先頭 8 + 2L バイト: 魔法 4 + 版 2 + 分位の数 2 + 分位×1000 を L 個。

    分位の並びが変わったら先頭が一致しなくなるので、古いファイルは捨てて作り直す。
    """
    lv = FORECAST_LEVELS
    return (FC_HIST_MAGIC + struct.pack("<HH", FC_HIST_VER, len(lv))
            + struct.pack("<%dH" % len(lv), *(int(round(q * 1000)) for q in lv)))


def _fch_record(slot, key, fc, used_now):
    """1 レコードを組む。各ステップの時刻は持たず、終端時刻と刻みから復元する。

    窓の突き合わせに使う終端時刻は予測そのものの最終ステップを採る（パネルの x1 ではなく）。
    両者は数秒ずれ得るので、時刻軸の起点と突き合わせの基準を同じ値にする。
    """
    pts, lv = fc.get("pts") or [], fc.get("levels") or []
    n, size = len(pts), len(lv)
    if n < 2 or size != len(FORECAST_LEVELS):
        return None
    step = (pts[-1][0] - pts[0][0]) / (n - 1)
    if not (step > 0):
        return None
    body, prev = array.array("H"), [0] * size
    for row in pts:
        if len(row) != size + 1:
            return None
        for i in range(size):
            v = min(65535, max(0, int(round(row[1 + i] * 10))))
            body.append(max(0, v - prev[i]))   # 分位は時間方向に単調なので 0 以上
            prev[i] = v
    kb = str(key).encode("utf-8")
    head = struct.pack(FC_HIST_HEAD, int(slot), len(kb), int(round(pts[-1][0])),
                       int(round(step * 100)), n,
                       min(65535, max(0, int(round((used_now or 0) * 10)))))
    return head + kb + body.tobytes()


def _fch_read(path):
    """追記ファイルを (slot, 生バイト) の列に分解する。

    先頭が今の分位と違う・途中で切れているなら (False, []) を返し、呼び出し側が作り直す。
    切り詰めは先頭からレコードをたどって組み直す（途中の位置へは飛べない）。
    """
    try:
        with open(path, "rb") as f:
            buf = f.read()
    except OSError:
        return False, []
    head = _fch_header()
    if not buf.startswith(head):
        return False, []
    size, i, out = len(FORECAST_LEVELS), len(head), []
    while i + FC_HIST_HEAD_SZ <= len(buf):
        slot, klen, _tend, _step, n, _u = struct.unpack_from(FC_HIST_HEAD, buf, i)
        end = i + FC_HIST_HEAD_SZ + klen + 2 * n * size
        if end > len(buf):
            return False, []
        out.append((slot, buf[i:end]))
        i = end
    if i != len(buf):
        return False, []
    return True, out


def append_forecast_hist(panels, now_epoch):
    """予測の分位を 15 分格子で追記し、PLAYBACK_SPAN より古いものを落とす。

    予測が付いているパネルをすべて書く。枠の対応付けは attach_forecast が付けた
    p["fc"] をそのまま使うので、ライブ表示と同じ規則（側＋リセット時刻の許容）になる。
    予測が無ければ何もしない。
    """
    slot = int(now_epoch // FC_HIST_SLOT) * FC_HIST_SLOT
    recs = []
    for p in panels:
        fc, key = p.get("fc"), p.get("key")
        if not fc or not key:
            continue
        rec = _fch_record(slot, key, fc, p.get("used_now"))
        if rec:
            recs.append((slot, rec))
    if not recs:
        return
    ok, old = _fch_read(FC_HIST_OUT)
    if ok and old and old[-1][0] >= slot:
        return                              # この格子はもう書いてある
    cutoff = now_epoch - PLAYBACK_SPAN
    keep = [r for r in (old if ok else []) if r[0] >= cutoff]
    tmp = "%s.%d.tmp" % (FC_HIST_OUT, os.getpid())
    try:
        with open(tmp, "wb") as f:
            f.write(_fch_header())
            for _slot, raw in keep + recs:
                f.write(raw)
        os.replace(tmp, FC_HIST_OUT)
    finally:
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass


def write_json(rows, crows, xrows, now_epoch, reset5_epoch, reset7_epoch):
    """pace.json をアトミック更新（tmp→replace、プロセス固有 tmp）。

    generated_at は最新サンプル ts（＝データのバージョン）。ブラウザはこの値の
    変化だけを見て再描画するので、内容が変わらない再生成では再描画しない。
    クレジット/Codex 側だけが更新された場合も再描画させるため、全ログの最大 ts を採る。
    """
    gv = None
    for v in (latest_ts(rows), latest_ts(crows), latest_ts(xrows)):
        if v is not None and (gv is None or v > gv):
            gv = v
    panels = build_panels(rows, now_epoch, reset5_epoch, reset7_epoch)
    month = build_month_panel(crows, now_epoch)
    if month is not None:
        panels.append(month)     # credits.jsonl が無い環境では 5h/7d の 2 枚のまま
    panels.extend(build_codex_panels(xrows, now_epoch))   # codex.jsonl が無ければ 0 枚
    panels = dedupe_panels(panels)       # 枠の構成が変わった直後は同じキーが 2 枚できる
    # Codex の窓長は attach_history が _win を取り除くので、その前に控える
    codex_wins = {p["key"]: p["_win"] for p in panels if p.get("_win") is not None}
    hist_x0 = attach_history(panels, rows, crows, xrows, now_epoch)
    attach_forecast(panels, now_epoch)   # router の予測があれば載せる。無ければ何も付かない
    try:
        append_forecast_hist(panels, now_epoch)   # 再生用に 15 分格子で追記
    except (OSError, ValueError, struct.error):
        pass                                      # 付加機能なので pace.json の生成は止めない
    data = {
        "generated_at": gv if gv is not None else now_epoch,
        "panels": panels,
        "playback": build_playback(rows, xrows, now_epoch, codex_wins),
    }
    if hist_x0 is not None:      # Align モード（全パネル共通の時間軸）の範囲
        data["hist_lo"] = hist_x0                                 # 履歴データの左端(再生の開始位置)
        data["hist_x0"] = max(now_epoch - HISTORY_SPAN, hist_x0)  # 通常表示の左端
        data["hist_x1"] = now_epoch
    tmp = f"{JSON_OUT}.{os.getpid()}.tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
        os.replace(tmp, JSON_OUT)
    finally:
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass


def main():
    os.makedirs(TP_DIR, exist_ok=True)

    # 複数セッション/コマンドからの同時生成を排他する（非ブロッキング）。
    # 取れなければ別プロセスが生成中なのでスキップ（そちらが最新の pace.json を出す）。
    # → 共有 tmp の破損と、古いプロセスが遅れて上書きする「後戻り」を防ぐ。
    try:
        import fcntl
        _plock = open(os.path.join(TP_DIR, ".plot.lock"), "w")  # noqa: SIM115
        try:
            fcntl.flock(_plock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return
    except ImportError:
        pass  # fcntl 非対応環境（Windows）は排他なしで続行（対象外だが安全側）

    rows = read_rows()
    rows.sort(key=lambda r: r.get("ts") or 0)   # 印は ts 昇順で付ける（追記順だが念のため）
    mark_old_window(rows)
    prune_if_needed(len(rows))
    crows = read_jsonl(CREDITS_LOG)         # 任意。無ければ月次パネルを出さない
    xrows = read_jsonl(CODEX_LOG)           # 任意。無ければ Codex パネルを出さない

    now_epoch = datetime.now().timestamp()
    reset5_epoch = max_reset(rows, "h5r")   # 最大 ts 行ではなく最大 resets_at＝最新窓（後退防止）
    reset7_epoch = max_reset(rows, "d7r")

    write_json(rows, crows, xrows, now_epoch, reset5_epoch, reset7_epoch)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # 生成失敗を statusline 等に波及させない
        print(f"pace-json: {e}", file=sys.stderr)
        sys.exit(0)
