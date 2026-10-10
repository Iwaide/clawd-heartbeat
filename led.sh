#!/usr/bin/env bash
# Claude Code hook → M5Atom Lite ステータス送信
# - stdin の hook JSON から session_id を抽出してセッション別に送る
# - ダイアログ(権限確認 / AskUserQuestion)表示中はマーカーを置き、
#   サブエージェント等の tool イベントによる赤の上書きを防ぐ
# - 拒否・中断は hook に流れないため、ダイアログ表示中だけトランスクリプトを
#   監視して痕跡(拒否の tool_result / 中断メッセージ)を検知したら赤を解除する
# - 手動実行(tty)時は stdin を読まず sid=default で送る
# - IP に届かなければ mDNS 名で引き直して再送する(DHCP 予約ができないルーター向け)

# ↓ 自分の Atom Lite の固定 IP に書き換える
ATOM_URL="http://192.168.1.50"
# IP が変わったときに引き直す mDNS 名(ファームの HOSTNAME + .local)。空にすると無効
ATOM_MDNS="atom.local"
ATOM_URL_CACHE="${TMPDIR:-/tmp}/claude-led-atom-url"
[ -s "$ATOM_URL_CACHE" ] && ATOM_URL=$(cat "$ATOM_URL_CACHE")

now_ms() { perl -MTime::HiRes=time -e 'printf("%.0f", time()*1000)' 2>/dev/null || echo 0; }

# 通常は IP 直打ち(mDNS の初回解決は Windows で 2〜3 秒かかり -m 1 に収まらないため)。
# 届かないときだけ mDNS で現在の IP を引き直してキャッシュし、同じ内容を再送する。
# 本体の電源断などで引けなかった場合は 60 秒間引き直しを止め、hook ごとの待ちを積み上げない
send_state() {
  local q="led?s=$1&sid=${2:-default}&ts=$(now_ms)" fail="$ATOM_URL_CACHE.fail" ip
  curl -s -m 1 --retry 2 --retry-all-errors "$ATOM_URL/$q" >/dev/null 2>&1 && return 0
  [ -n "$ATOM_MDNS" ] || return 1
  [ -n "$(find "$fail" -mmin -1 2>/dev/null)" ] && return 1
  ip=$(curl -s -m 5 -o /dev/null -w '%{remote_ip}' "http://$ATOM_MDNS/" 2>/dev/null)
  if [ -z "$ip" ]; then touch "$fail"; return 1; fi
  printf 'http://%s' "$ip" > "$ATOM_URL_CACHE.$$" && mv -f "$ATOM_URL_CACHE.$$" "$ATOM_URL_CACHE"
  ATOM_URL="http://$ip"
  curl -s -m 1 --retry 2 --retry-all-errors "$ATOM_URL/$q" >/dev/null 2>&1
}
file_size() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0; }

# ダイアログ応答待ちの間、トランスクリプト(JSONL)の追記分を 1 秒間隔で監視する。
# 「No で拒否」「Ctrl+C で中断」はどの hook イベントも発火しない(実測)が、
# トランスクリプトには即座に記録されるため、それを検知して赤を解除する。
# パターンは実際の JSONL 構造への構造的マッチ(会話文中の引用は \" にエスケープ
# されるため誤発火しない)。マーカーが消えたら通常経路で解決済みとして終了。
watch_dialog() {
  local tr="$1" marker="$2" sid="$3"
  local deny='"content"[[:space:]]*:[[:space:]]*"The user doesn'\''t want to proceed with this tool use'
  local intr='"text"[[:space:]]*:[[:space:]]*"\[Request interrupted by user'
  local size new end
  size=$(file_size "$tr")
  end=$(( $(date +%s) + 600 ))     # マーカーの TTL と同じ 10 分で自然終了
  while [ "$(date +%s)" -lt "$end" ]; do
    sleep 1
    [ -f "$marker" ] || return 0   # 承認完了・新プロンプト等の通常経路で解決済み
    new=$(file_size "$tr")
    if [ "$new" -gt "$size" ]; then
      if tail -c +"$((size + 1))" "$tr" 2>/dev/null | grep -Eq "$deny|$intr"; then
        rm -f "$marker"
        send_state idle "$sid"     # ターンが続く場合は直後の hook がすぐ上書きする
        return 0
      fi
      size=$new
    fi
  done
}

state="$1"
sid=""
if [ ! -t 0 ]; then
  input=$(cat)
  jget() { printf '%s' "$input" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1; }
  sid=$(jget session_id)
  event=$(jget hook_event_name)
  tool=$(jget tool_name)
  tuid=$(jget tool_use_id)
  tmp="${TMPDIR:-/tmp}"
  marker="$tmp/claude-led-wait-${sid:-default}"     # "<tuid|-> <tool>" ダイアログ応答待ち
  pending="$tmp/claude-led-pending-${sid:-default}" # "<tuid> <tool>" 直近の PreToolUse

  # マーカーの TTL(10分): 解除イベントの取りこぼしで赤が永続しないように
  if [ -f "$marker" ]; then
    age=$(( $(date +%s) - $(stat -f %m "$marker" 2>/dev/null || stat -c %Y "$marker" 2>/dev/null || echo 0) ))
    [ "$age" -gt 600 ] && rm -f "$marker"
  fi

  # 選択肢ダイアログ(AskUserQuestion)の表示も承認待ちと同じ扱いにする
  if [ "$state" = "tool" ] && [ "$event" = "PreToolUse" ] && [ "$tool" = "AskUserQuestion" ]; then
    state="wait"
  fi

  # PermissionRequest に tool_use_id が無いため、直前の PreToolUse を控えておいて紐付ける
  if [ "$event" = "PreToolUse" ] && [ -n "$tuid" ]; then
    printf '%s %s' "$tuid" "$tool" > "$pending"
  fi

  if [ "$state" = "wait" ]; then
    # ダイアログ表示: どのツール呼び出しの応答待ちかを記録
    if [ -n "$tuid" ]; then
      printf '%s %s' "$tuid" "$tool" > "$marker"          # AskUserQuestion(PreToolUse 由来)
    else
      ptuid=""; ptool=""
      [ -f "$pending" ] && read -r ptuid ptool < "$pending"
      if [ -n "$ptuid" ] && [ "$ptool" = "$tool" ]; then
        printf '%s %s' "$ptuid" "$tool" > "$marker"       # PermissionRequest(PreToolUse から補完)
      else
        printf '%s %s' "-" "$tool" > "$marker"            # 補完失敗時はツール名だけで照合
      fi
    fi
    # 拒否・中断の監視を起動(ダイアログ 1 回ごとの短命プロセス)
    tpath=$(jget transcript_path)
    if [ -n "$tpath" ] && [ -f "$tpath" ]; then
      ( watch_dialog "$tpath" "$marker" "${sid:-default}" ) </dev/null >/dev/null 2>&1 &
    fi
  elif [ "$state" = "tool" ] && [ -f "$marker" ]; then
    # ダイアログ応答待ち中に届く tool イベントの扱い:
    # サブエージェントは同じ session_id で hook を発火し続けるため、
    # そのまま送ると赤(wait)が白(tool)に上書きされてしまう
    case "$event" in
      UserPromptSubmit)
        rm -f "$marker"       # 新しいプロンプト = ダイアログは解決済み
        ;;
      PostToolUse|PostToolUseFailure)
        waiting=""; wtool=""
        read -r waiting wtool < "$marker" 2>/dev/null || true
        if { [ "$waiting" != "-" ] && [ "$tuid" = "$waiting" ]; } \
           || { [ "$waiting" = "-" ] && [ "$tool" = "$wtool" ]; }; then
          rm -f "$marker"     # 待っていた呼び出しの完了 = ダイアログ応答済み
        else
          state="wait"        # 別の呼び出し(サブエージェント等)の完了: 赤を維持
        fi
        ;;
      *)
        state="wait"          # ダイアログ待ち中の PreToolUse 等も赤を維持
        ;;
    esac
  elif [ "$state" != "tool" ]; then
    rm -f "$marker" "$pending"   # done / err / idle でダイアログ待ちは終了
  fi
fi
send_state "$state" "$sid"
