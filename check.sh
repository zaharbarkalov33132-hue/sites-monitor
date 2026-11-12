#!/usr/bin/env bash
# Проверяет каждый сайт из sites.txt. Упал (3 неудачи подряд) — открывает issue на владельца,
# поднялся — закрывает. SSL истекает меньше чем через 14 дней — отдельное предупреждение.
set -u
export LC_NUMERIC=C
owner="${GITHUB_REPOSITORY_OWNER}"
down_label="сайт упал"
ssl_label="ssl истекает"
gh label create "$down_label" --color d73a4a --force >/dev/null
gh label create "$ssl_label" --color fbca04 --force >/dev/null

open_issue() { # $1 заголовок, $2 метка → номер открытой задачи или пусто
  gh issue list --state open --label "$2" --search "in:title \"$1\"" --json number,title \
    --jq ".[] | select(.title == \"$1\") | .number" | head -n1
}

summary="| Сайт | Статус | Время ответа | SSL до |\n|---|---|---|---|\n"

# список читаем через дескриптор 3, чтобы gh/curl внутри цикла не съели его со stdin
while read -r url <&3; do
  url="${url%$'\r'}"
  host="${url#https://}"; host="${host%%/*}"
  code=000; time=0
  for try in 1 2 3; do
    read -r code time < <(curl -sS -o /dev/null -L --max-time 20 -A "sites-monitor" \
      -w '%{http_code} %{time_total}\n' "$url" 2>/dev/null || echo "000 0")
    [[ "$code" =~ ^[23] ]] && break
    sleep 15
  done

  title="🔴 $host не отвечает"
  num="$(open_issue "$title" "$down_label")"
  if [[ "$code" =~ ^[23] ]]; then
    status="✅ работает"
    if [[ -n "$num" ]]; then
      gh issue comment "$num" --body "✅ Сайт снова работает ($(date -u '+%Y-%m-%d %H:%M') UTC), код $code."
      gh issue close "$num"
    fi
  else
    status="🔴 упал (код $code)"
    if [[ -z "$num" ]]; then
      gh issue create --title "$title" --label "$down_label" --assignee "$owner" --body \
        "@$owner сайт $url не отвечает: код **$code** после 3 попыток ($(date -u '+%Y-%m-%d %H:%M') UTC). Проверь хостинг. Задача закроется сама, когда сайт поднимется."
    fi
  fi

  ssl_end="$(echo | openssl s_client -servername "$host" -connect "$host:443" 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
  ssl_day="—"
  if [[ -n "$ssl_end" ]]; then
    ssl_day="$(date -u -d "$ssl_end" '+%Y-%m-%d')"
    days=$(( ( $(date -u -d "$ssl_end" +%s) - $(date -u +%s) ) / 86400 ))
    stitle="⚠️ $host: SSL-сертификат истекает"
    snum="$(open_issue "$stitle" "$ssl_label")"
    if (( days < 14 )) && [[ -z "$snum" ]]; then
      gh issue create --title "$stitle" --label "$ssl_label" --assignee "$owner" --body \
        "@$owner сертификат $host истекает $ssl_day (через $days дн.). Продли его в панели хостинга."
    elif (( days >= 14 )) && [[ -n "$snum" ]]; then
      gh issue close "$snum" --comment "Сертификат продлён до $ssl_day."
    fi
  fi

  printf '| %s | %s | %.1f с | %s |\n' "$url" "$status" "$time" "$ssl_day" >> status-rows.tmp
done 3< <(grep -Ev '^\s*(#|$)' sites.txt)

{
  echo "# Состояние сайтов"
  echo
  echo "Последняя проверка: $(date -u '+%Y-%m-%d %H:%M') UTC (проверка каждые 5 минут)."
  echo
  printf '%b' "$summary"
  cat status-rows.tmp
} > status.md
rm -f status-rows.tmp
cat status.md
cat status.md >> "$GITHUB_STEP_SUMMARY"
