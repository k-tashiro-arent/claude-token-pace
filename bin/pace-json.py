#!/usr/bin/env python3
"""pace.jsonl -> pace.json（ブラウザ用の処理済み系列）。標準ライブラリのみ・matplotlib/PNG 不要。

- 入力 : $TOKEN_PACE_DIR/pace.jsonl     (1行1サンプル。sampler が append)
         $TOKEN_PACE_DIR/credits.jsonl (月次クレジット枠。credits-fetch.py が append。任意)
- 出力 : $TOKEN_PACE_DIR/pace.json   (tmp -> os.replace でアトミック更新)
- 設定 : $TOKEN_PACE_DIR/biz-hours.json  (標準ペースの基準。無い/不正なら既定 月-金 9-18)

used% の単調化: レート枠はアカウント共有だが、各セッションは自分が最後に受けた API レスポンス
時点の used%/resets_at しか持たない。pace.jsonl には複数セッションが混在するため、
(1)対象窓の resets_at に一致する観測だけ採用し (2)running-max で包絡線化する。
target 窓は「最大 ts 行の resets_at」ではなく「観測された resets_at の最大値」で選ぶ
(max_reset)。idle/古いセッションが fresh な ts で古い resets_at を書いても窓が後退しない。
"""

import json
import math
import os
import sys
from datetime import datetime

TP_DIR = os.path.expanduser(os.environ.get("TOKEN_PACE_DIR") or "~/.claude/token-pace")
LOG = os.path.join(TP_DIR, "pace.jsonl")
CREDITS_LOG = os.path.join(TP_DIR, "credits.jsonl")
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


def window_series(rows, val_key, reset_key, target_reset, lo_epoch, hi_epoch):
    """対象窓の観測だけを取り出し、時刻昇順・envelope した (xs, ys) を返す。

    - target_reset に一致する resets_at の観測のみ採用（別窓の遅延観測を除外）。
    - stale スナップショット除外: 新鮮な観測は必ず「5h リセット(h5r) が観測時点より未来」。
      h5r <= ts の行は、セッション再開直後などに statusLine が出した過去の rate_limits
      スナップショット（別=過去の 5h 窓の値）なので捨てる。7d 窓は 7 日長のため古い
      スナップショットでも d7r が現窓と一致してしまい、これを弾かないとスパイクになる。
    """
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
        h5r = r.get("h5r")   # 最速リセット。stale 判定に使う（両パネル共通）
        if h5r is not None:
            try:
                if float(h5r) <= ts:
                    continue   # 観測時点で既に過ぎた 5h リセット = 古いスナップショット
            except (ValueError, TypeError):
                pass
        if target_reset is not None and rk is not None:
            try:
                if float(rk) != target_reset:
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
    used = [[x.timestamp(), y] for x, y in zip(xs, ys)]
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
    used = [[x.timestamp(), y] for x, y in zip(xs, ys)]
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
    """epoch を含む月の [1日00:00, 翌月1日00:00)(ローカル) を返す。"""
    d = datetime.fromtimestamp(epoch)
    y, m = (d.year + 1, 1) if d.month == 12 else (d.year, d.month + 1)
    return datetime(d.year, d.month, 1).timestamp(), datetime(y, m, 1).timestamp()


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


def build_month_panel(crows, now_epoch):
    """月次クレジット枠（extra usage）のパネル。credits.jsonl が無ければ None。

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


def _playback_segments(rows, start, now_epoch, key, val_key, reset_key, win_len, even_fn, xmode):
    """[start, now] に重なる各窓（観測された reset_key ごと）を古い順にセグメント化して返す。

    各窓は既存の window_series で used 包絡線を計算する。ビューアは再生カーソルが窓境界を
    越えるたびにセグメントを切り替える＝その枠のリセットが再現される。
    """
    resets = set()
    for r in rows:
        v = r.get(reset_key)
        try:
            v = float(v)
        except (ValueError, TypeError):
            continue
        if v > start and (v - win_len) < now_epoch:   # 窓[v-win, v] が [start, now] と重なる
            resets.add(v)

    segs = []
    for rr in sorted(resets):
        xs, ys = window_series(rows, val_key, reset_key, rr, rr - win_len, rr)
        used = [[x.timestamp(), y] for x, y in zip(xs, ys)]
        if not used:
            continue
        segs.append({
            "key": key, "x0": rr - win_len, "x1": rr, "xmode": xmode,
            "reset_label": _label(rr, xmode),
            "even": even_fn(rr - win_len, rr),
            "used": used,
        })
    return segs


def build_playback(rows, now_epoch):
    """直近 PLAYBACK_SPAN(=7d) を早送り再生するためのセグメント列（5h/7d 両パネル分）を返す。

    - 期間: [max(now-7d, 最古サンプル), now]（履歴が 7d 未満なら最古サンプルから）。
    - この期間に重なる 5h 窓・7d 窓をそれぞれ古い順に列挙する。7d スパンでは 5h 窓は多数回、
      7d 窓も（now-7d が現 7d 窓の開始より前になるため）1 回リセット境界をまたぎ得る。
      ビューアは各パネルで再生カーソルが境界を越えるたびに窓を切り替える＝リセットが再現される。
    - 履歴が短ければ各パネル 1 窓に縮退（リセット無し）。

    データが無い/両パネルともセグメントが作れない場合は None。
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

    def biz_even(x0, x1):
        bx, by = biz_baseline(x0, x1)
        return [[x.timestamp(), y] for x, y in zip(bx, by)]

    seg5h = _playback_segments(rows, start, now_epoch, "5h", "h5", "h5r", FIVE_HOUR,
                               lambda x0, x1: [[x0, 0.0], [x1, 100.0]], "time")
    seg7d = _playback_segments(rows, start, now_epoch, "7d", "d7", "d7r", SEVEN_DAY,
                               biz_even, "date")
    if not seg5h and not seg7d:
        return None
    return {"start": start, "now": now_epoch, "seg5h": seg5h, "seg7d": seg7d}


def write_json(rows, crows, now_epoch, reset5_epoch, reset7_epoch):
    """pace.json をアトミック更新（tmp→replace、プロセス固有 tmp）。

    generated_at は最新サンプル ts（＝データのバージョン）。ブラウザはこの値の
    変化だけを見て再描画するので、内容が変わらない再生成では再描画しない。
    クレジット側だけが更新された場合も再描画させるため、両ログの最大 ts を採る。
    """
    gv, gc = latest_ts(rows), latest_ts(crows)
    if gc is not None and (gv is None or gc > gv):
        gv = gc
    panels = build_panels(rows, now_epoch, reset5_epoch, reset7_epoch)
    month = build_month_panel(crows, now_epoch)
    if month is not None:
        panels.append(month)     # credits.jsonl が無い環境では 5h/7d の 2 枚のまま
    data = {
        "generated_at": gv if gv is not None else now_epoch,
        "panels": panels,
        "playback": build_playback(rows, now_epoch),
    }
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
    prune_if_needed(len(rows))
    crows = read_jsonl(CREDITS_LOG)         # 任意。無ければ月次パネルを出さない

    now_epoch = datetime.now().timestamp()
    reset5_epoch = max_reset(rows, "h5r")   # 最大 ts 行ではなく最大 resets_at＝最新窓（後退防止）
    reset7_epoch = max_reset(rows, "d7r")

    write_json(rows, crows, now_epoch, reset5_epoch, reset7_epoch)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # 生成失敗を statusline 等に波及させない
        print(f"pace-json: {e}", file=sys.stderr)
        sys.exit(0)
