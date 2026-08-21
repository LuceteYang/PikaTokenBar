#!/usr/bin/env python3
"""설정 스크린샷(assets/settings*.png) 재생성.

라이브 팝오버 캡처가 아니라 SettingsView 의 행 구성을 HTML 로 옮겨 Chrome headless 로 그린다
(팝오버를 스크립트로 열어 캡처할 방법이 없어 upstream 도 이 방식이었다).

    python3 scripts/gen-settings-screenshots.py

두 종류를 만든다:
  settings.png / -ko / -ja           전체 화면 (고급 섹션은 접힌 상태 = 앱 기본)
  settings-advanced.png / -ko / -ja  고급 섹션을 펼친 상세 — 세션 키 행이 여기 있다

**함정 두 개(실측):**
  · 구 `--headless` 는 긴 페이지에서 푸터를 상단에 반투명하게 재합성한 잔상을 남긴다 → `--headless=new`.
  · 콘텐츠 높이를 내림하면 마지막 픽셀 행이 잘려 같은 잔상이 생긴다 → `int(h) + 2`.

문구는 `Sources/PokeTokenBar/Core/Localization.swift` 의 `t(ko, en, ja, es)` 에서 가져온다
(es 는 스크린샷 없음). 릴리스마다 VERSION 을 새 버전으로 바꾼다 — 푸터에 박힌다.
"""
import subprocess, sys, os, re

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(REPO, "assets")
TMP = os.path.join(REPO, "build")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
VERSION = "1.3.0"

# ko, en, ja — Localization.swift 의 t(ko, en, ja, es) 순서에서 es 만 뺐다.
S = {
 "settings":      ("설정", "Settings", "設定"),
 "back":          ("뒤로", "Back", "戻る"),
 "general":       ("일반", "General", "一般"),
 "language":      ("언어", "Language", "言語"),
 "langValue":     ("한국어", "English", "日本語"),
 "repLabel":      ("대표 포켓몬", "Representative Pokémon", "代表ポケモン"),
 "repValue":      ("현재 포켓몬 따라가기", "Follow current companion", "現在のポケモンに合わせる"),
 "refresh":       ("새로고침 간격", "Refresh interval", "更新間隔"),
 "refreshValue":  ("2분", "2 min", "2分"),
 "animLabel":     ("애니메이션", "Animation", "アニメーション"),
 "animHint":      ("부드러울수록 배터리를 더 씁니다", "Smoother uses more battery",
                   "滑らかにするとバッテリー消費が増えます"),
 "animValue":     ("기본", "Balanced", "標準"),
 "limitDisplay":  ("한도 표시 방식", "Limit display", "上限の表示"),
 "limitUsed":     ("사용량", "Used", "使用量"),
 "limitRemain":   ("남은 양", "Remaining", "残量"),
 "launch":        ("로그인 시 자동 시작", "Launch at login", "ログイン時に自動起動"),
 "menuBar":       ("메뉴바에 표시", "Show in menu bar", "メニューバーに表示"),
 "todayTokens":   ("오늘 토큰", "Today's tokens", "本日のトークン"),
 "todayCost":     ("오늘 비용 ($)", "Today's cost ($)", "本日のコスト ($)"),
 "limitPct":      ("한도 %", "Limit %", "上限 %"),
 "allOff":        ("전부 끄면 캐릭터만 표시됩니다", "All off shows only the character",
                   "すべてオフにするとキャラクターのみ表示"),
 "pet":           ("플로팅 펫", "Floating Pet", "フローティングペット"),
 "petEnable":     ("플로팅 펫 표시", "Show floating pet", "フローティングペットを表示"),
 "petHint":       ("포켓몬이 화면 위에 떠 있어요 — 드래그로 위치를 옮길 수 있어요",
                   "Your Pokémon floats over the screen — drag to reposition",
                   "ポケモンが画面の上に浮かびます — ドラッグで移動できます"),
 "petSize":       ("크기", "Size", "サイズ"),
 "petBubble":     ("말풍선으로 알림 받기", "Show notifications as bubbles", "通知を吹き出しで表示"),
 "notifications": ("알림", "Notifications", "通知"),
 "limitAlerts":   ("한도 알림", "Limit alerts", "上限通知"),
 "warning":       ("경고", "Warning", "警告"),
 "critical":      ("임박", "Critical", "切迫"),
 "companionEv":   ("Companion 이벤트 (부화·진화·졸업)", "Companion events (hatch / evolve / graduate)",
                   "コンパニオンイベント（孵化・進化・卒業）"),
 "statusLabel":   ("프로바이더 상태 확인", "Provider status checks", "プロバイダー状態チェック"),
 "statusHint":    ("Claude·OpenAI 장애를 팝오버에 표시 (알림 아님)",
                   "Show Claude / OpenAI incidents in the popover (not a notification)",
                   "Claude・OpenAIの障害をポップオーバーに表示（通知ではない）"),
 "updates":       ("업데이트", "Updates", "アップデート"),
 "updateNotif":   ("업데이트 알림", "Update notifications", "アップデート通知"),
 "checkUpdates":  ("업데이트 확인", "Check for updates", "アップデートを確認"),
 "checkNow":      ("지금 확인", "Check now", "今すぐ確認"),
 "transfer":      ("백업 & 이전", "Backup & Transfer", "バックアップと移行"),
 "exportLabel":   ("세이브 내보내기", "Export save", "セーブを書き出す"),
 "exportHint":    ("도감·누적 토큰·가방·현재 포켓몬을 파일 하나로 저장해요",
                   "Saves your Pokédex, lifetime tokens, Bag, and current Pokémon as one file",
                   "図鑑・累計トークン・バッグ・現在のポケモンを1つのファイルに保存します"),
 "exportBtn":     ("내보내기…", "Export…", "書き出す…"),
 "importLabel":   ("세이브 불러오기", "Import save", "セーブを読み込む"),
 "importHint":    ("다른 Mac에서 내보낸 파일을 골라 이 Mac으로 이어서 키워요",
                   "Pick a file exported from another Mac and continue here",
                   "他のMacから書き出したファイルを選んでこのMacで続けます"),
 "importBtn":     ("불러오기…", "Import…", "読み込む…"),
 "advanced":      ("고급", "Advanced", "詳細"),
 "advancedRow":   ("고급 설정 · 진단", "Advanced · diagnostics", "詳細設定・診断"),
 "about":         ("정보 & 지원", "About & Support", "情報とサポート"),
 "report":        ("문제점 알리기", "Report a problem", "問題を報告"),
 "reportHint":    ("이슈에 로그 파일을 첨부해 주시면 원인 파악에 큰 도움이 돼요.",
                   "Attaching the log file to the issue helps a lot with diagnosis.",
                   "イシューにログファイルを添付していただくと原因の特定に役立ちます。"),
 "showLog":       ("로그 파일 보기", "Show log file", "ログファイルを表示"),
 "sessionKey":    ("claude.ai 세션 키", "claude.ai session key", "claude.ai セッションキー"),
 "sessionKeyHint": ("Keychain 팝업 없이 공식 한도를 조회합니다. 브라우저 개발자도구 → Application → Cookies → claude.ai → sessionKey 값을 붙여넣으세요.",
                   "Fetches official limits with no Keychain pop-up. Paste the value from DevTools → Application → Cookies → claude.ai → sessionKey.",
                   "Keychain のポップアップなしで公式上限を取得します。開発者ツール → Application → Cookies → claude.ai → sessionKey の値を貼り付けてください。"),
 "sessionKeySaved": ("설정됨", "Saved", "設定済み"),
 "sessionKeyNote": ("키는 이 Mac 의 앱 폴더에 본인만 읽을 수 있는 파일로 저장됩니다(암호화 아님). 브라우저에서 로그아웃하면 즉시 무효화됩니다.",
                   "The key is stored in this Mac's app folder as an owner-only file (not encrypted). Logging out in your browser invalidates it immediately.",
                   "キーはこの Mac のアプリフォルダに本人のみ読み取り可能なファイルとして保存されます(暗号化なし)。ブラウザでログアウトすると即時無効になります。"),
 "orgLabel":      ("조직", "Organization", "組織"),
 "orgValue":      ("회사 Team Plan", "Company Team Plan", "会社 Team Plan"),
 "save":          ("저장", "Save", "保存"),
 "delete":        ("삭제", "Delete", "削除"),
 "keychainOff":   ("Keychain 접근 끄기", "Disable Keychain access", "Keychainアクセスを無効化"),
 "keychainOffHint": ("켜면 Keychain 접근 허용 팝업이 더 안 뜹니다 — 공식 한도(%)만 숨겨지고 토큰·비용은 그대로",
                   "When on, no more Keychain permission pop-ups — only official limits (%) are hidden; tokens/cost stay",
                   "オンにするとKeychain許可のポップアップが出なくなります — 公式上限(%)のみ非表示、トークン・費用はそのまま"),
 "refreshToken":  ("한도 토큰 캐시 갱신", "Refresh limit token cache", "上限トークンキャッシュを更新"),
 "refreshTokenHint": ("누를 때만 Keychain 을 읽어요 — 자동 폴링은 안 읽어 팝업이 안 떠요. 토큰 만료 후 이 버튼으로 한도 갱신",
                   "Reads Keychain only when pressed — auto-polling never does, so no pop-ups. Refresh limits here after the token expires",
                   "押した時のみKeychainを読みます — 自動更新では読まずポップアップも出ません。トークン期限切れ後はこのボタンで上限を更新"),
 "aggNote":       ("토큰 집계 기준: totalTokens (input + output + cache, 로컬 날짜)",
                   "Token basis: totalTokens (input + output + cache, local date)",
                   "集計基準: totalTokens (input + output + cache, ローカル日付)"),
 "finder":        ("Finder", "Finder", "Finder"),
}
IDX = {"ko": 0, "en": 1, "ja": 2}

CSS = """
*{box-sizing:border-box;margin:0;padding:0}
body{width:360px;background:#1c1c1e;color:#fff;
 font:13px/1.35 -apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",sans-serif;
 -webkit-font-smoothing:antialiased}
.hdr{display:flex;align-items:center;justify-content:center;height:38px;position:relative;
 border-bottom:1px solid #2f2f31}
.hdr .t{font-size:14px;font-weight:600}
.hdr .b{position:absolute;left:12px;color:#0a84ff;font-size:13px}
.sec{font-size:10px;font-weight:600;letter-spacing:.7px;text-transform:uppercase;color:#8b8b90;
 padding:14px 16px 6px}
.card{background:#2c2c2e;border-radius:10px;margin:0 12px;overflow:hidden}
.row{display:flex;align-items:center;gap:10px;padding:9px 14px;min-height:38px}
.row+.row{border-top:1px solid #3a3a3c}
.lbl{flex:1;min-width:0}
.lbl .h{font-size:10.5px;color:#8b8b90;margin-top:1px}
.note{font-size:10.5px;color:#8b8b90;padding:6px 16px 0}
.pill{background:#5b5b5e;border-radius:5px;padding:3px 7px;font-size:11.5px;white-space:nowrap;
 display:inline-flex;align-items:center;gap:5px;max-width:150px}
.pill .x{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.row.one .lbl{white-space:nowrap;font-size:11.5px}
.pill .c{font-size:8px;opacity:.75}
.btn{background:#5b5b5e;border-radius:5px;padding:4px 9px;font-size:11.5px;white-space:nowrap}
.seg{display:flex;background:#3a3a3c;border-radius:6px;padding:2px}
.seg span{padding:2px 9px;font-size:11.5px;border-radius:4px}
.seg .on{background:#68686c}
.tog{width:32px;height:19px;border-radius:10px;background:#48484a;position:relative;flex:none}
.tog.on{background:#32d74b}
.tog i{position:absolute;top:1.5px;left:1.5px;width:16px;height:16px;border-radius:50%;
 background:#fff;display:block}
.tog.on i{left:14.5px}
.sld{flex:1;height:3px;background:#48484a;border-radius:2px;position:relative;margin:0 6px}
.sld i{position:absolute;top:-5.5px;width:14px;height:14px;border-radius:50%;background:#fff;
 box-shadow:0 1px 2px rgba(0,0,0,.4)}
.val{font-size:11.5px;color:#c9c9cd;min-width:38px;text-align:right}
.chev{color:#8b8b90;font-size:12px}
.ftr{display:flex;gap:7px;align-items:center;font-size:10.5px;color:#8b8b90;padding:14px 16px 12px;
 margin-top:6px;border-top:1px solid #2f2f31}
.ftr a{color:#8b8b90;text-decoration:underline}
.ftr .hrt{color:#ff375f}
.badge{background:rgba(50,215,75,.18);color:#32d74b;border-radius:4px;padding:1px 5px;font-size:9.5px}
.field{flex:1;background:#1c1c1e;border:1px solid #48484a;border-radius:5px;padding:4px 7px;
 font-size:11.5px;color:#6e6e73;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.ttl{display:flex;align-items:center;gap:6px}
"""


def html(lang, advanced=False):
    i = IDX[lang]
    def s(k):
        return S[k][i]

    def tog(on):
        return f'<div class="tog{" on" if on else ""}"><i></i></div>'

    def pill(text):
        return f'<div class="pill"><span class="x">{text}</span><span class="c">⌄</span></div>'

    def row(label, right, hint=None, one=False):
        h = f'<div class="h">{hint}</div>' if hint else ""
        cls = "row one" if one else "row"
        return f'<div class="{cls}"><div class="lbl">{label}{h}</div>{right}</div>'

    def card(*rows):
        return '<div class="card">' + "".join(rows) + "</div>"

    def sec(title):
        return f'<div class="sec">{title}</div>'

    slider = lambda pct: f'<div class="sld"><i style="left:calc({pct}% - 7px)"></i></div>'

    # 고급 섹션을 펼친 모습 — 세션 키 행이 여기 산다(앱에서도 이 disclosure 안에 있다).
    advanced_rows = card(
        f'<div class="row"><div class="lbl">{s("advancedRow")}</div><span class="chev">⌄</span></div>',
        row(f'<div class="ttl"><span>{s("sessionKey")}</span>'
            f'<span class="badge">{s("sessionKeySaved")}</span></div>',
            "", s("sessionKeyHint")),
        f'<div class="row"><div class="field">••••••••</div>'
        f'<div class="btn">{s("save")}</div><div class="btn">{s("delete")}</div></div>',
        row(s("orgLabel"), pill(s("orgValue"))),
        f'<div class="note" style="padding:6px 14px 8px">{s("sessionKeyNote")}</div>',
        row(s("keychainOff"), tog(False), s("keychainOffHint")),
        row(s("refreshToken"), f'<div class="btn">{s("refreshToken")}</div>', s("refreshTokenHint")),
        f'<div class="note" style="padding:8px 14px">{s("aggNote")}</div>',
    )

    if advanced:
        # 고급 섹션만 잘라 보여준다 — 전체 화면에 펼쳐 넣으면 3800px 이 넘어 README 에서 못 읽는다.
        parts = [
            f'<div class="hdr"><span class="b">‹ {s("back")}</span><span class="t">{s("settings")}</span></div>',
            sec(s("advanced")),
            advanced_rows,
            '<div style="height:10px"></div>',
        ]
        return ("<!doctype html><html lang=%s><head><meta charset=utf-8><style>%s</style></head>"
                "<body>%s<script>document.title=document.body.getBoundingClientRect().height"
                "</script></body></html>") % (lang, CSS, "".join(parts))

    parts = [
        f'<div class="hdr"><span class="b">‹ {s("back")}</span><span class="t">{s("settings")}</span></div>',
        sec(s("general")),
        card(
            row(s("language"), pill(s("langValue"))),
            row(s("repLabel"), pill(s("repValue")), one=True),
            row(s("refresh"), pill(s("refreshValue"))),
            row(s("animLabel"), pill(s("animValue")), s("animHint")),
            row(s("limitDisplay"),
                f'<div class="seg"><span class="on">{s("limitUsed")}</span><span>{s("limitRemain")}</span></div>'),
            row(s("launch"), tog(True)),
        ),
        sec(s("menuBar")),
        card(
            row(s("todayTokens"), tog(True)),
            row(s("todayCost"), tog(False)),
            row(s("limitPct"), tog(True)),
        ),
        f'<div class="note">{s("allOff")}</div>',
        sec(s("pet")),
        card(
            row(s("petEnable"), tog(True), s("petHint")),
            row(s("petSize"), slider(38) + '<div class="val">96px</div>'),
            row(s("petBubble"), tog(True)),
        ),
        sec(s("notifications")),
        card(
            row(s("limitAlerts"), tog(True)),
            row(s("warning"), slider(80) + '<div class="val">80%</div>'),
            row(s("critical"), slider(95) + '<div class="val">95%</div>'),
            row(s("companionEv"), tog(True)),
            row(s("statusLabel"), tog(True), s("statusHint")),
        ),
        sec(s("updates")),
        card(
            row(s("updateNotif"), tog(True)),
            row(s("checkUpdates"), f'<div class="btn">{s("checkNow")}</div>'),
        ),
        sec(s("transfer")),
        card(
            row(s("exportLabel"), f'<div class="btn">{s("exportBtn")}</div>', s("exportHint")),
            row(s("importLabel"), f'<div class="btn">{s("importBtn")}</div>', s("importHint")),
        ),
        sec(s("advanced")),
        card(row(f'<span class="chev">›</span>&nbsp; {s("advancedRow")}', "")),
        sec(s("about")),
        card(
            row(s("report"), f'<div class="btn">{s("report")}</div>', s("reportHint")),
            row(s("showLog"), f'<div class="btn">{s("finder")}</div>'),
        ),
        f'<div class="ftr"><span>v{VERSION}</span><span>·</span><a>GitHub</a><span>·</span>'
        f'<a>Web</a><span>·</span><span class="hrt">♥</span><a>Sponsor</a></div>',
    ]
    return ("<!doctype html><html lang=%s><head><meta charset=utf-8><style>%s</style></head>"
            "<body>%s<script>document.title=document.body.getBoundingClientRect().height"
            "</script></body></html>") % (lang, CSS, "".join(parts))


def measure(path):
    """Chrome 두 번 돌리는 이유: --screenshot 은 window-size 만큼만 그린다 — 콘텐츠 높이를 먼저 재야
    아래쪽 빈 공간 없이 딱 맞게 캡처된다(크롭 도구가 이 기기에 없다)."""
    dom = subprocess.run([CHROME, "--headless", "--disable-gpu", "--dump-dom",
                          "--virtual-time-budget=1500", "file://" + path],
                         capture_output=True, text=True).stdout
    m = re.search(r"<title>([0-9.]+)</title>", dom)
    return float(m.group(1)) if m else None


def shoot(path, out, height):
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    "--force-device-scale-factor=2", f"--window-size=360,{height}",
                    "--virtual-time-budget=1500", "--screenshot=" + out, "file://" + path],
                   capture_output=True, check=True)


os.makedirs(TMP, exist_ok=True)
TARGETS = [
    ("en", "settings.png", False), ("ko", "settings-ko.png", False), ("ja", "settings-ja.png", False),
    ("en", "settings-advanced.png", True), ("ko", "settings-advanced-ko.png", True),
    ("ja", "settings-advanced-ja.png", True),
]

for lang, name, advanced in TARGETS:
    p = os.path.join(TMP, f"{name}.html")
    open(p, "w", encoding="utf-8").write(html(lang, advanced))
    h = measure(p)
    if h is None:
        sys.exit(f"{lang}: 높이 측정 실패")
    out = os.path.join(OUT, name)
    shoot(p, out, int(h) + 2)
    size = subprocess.run(["file", out], capture_output=True, text=True).stdout.strip()
    print(f"{name}: css_h={h:.1f} -> {size.split(': ',1)[1][:60]}")
    os.remove(p)
