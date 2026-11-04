# ssb-youtube-v6-patch

Маршрутизация трафика **YouTube через IPv6-выход** OUT-сервера (по аналогии с
[ssb-gemini-v6-patch](https://github.com/Anton98567/ssb-gemini-v6-patch),
[ssb-openai-v6-patch](https://github.com/Anton98567/ssb-openai-v6-patch),
[ssb-claude-v6-patch](https://github.com/Anton98567/ssb-claude-v6-patch)).

Патч добавляет в sing-box-конфиг OUT-сервера:
- outbound `youtube-v6` (direct с `inet6_bind_address` = исходящий IPv6 сервера);
- route-правило: домены YouTube → `youtube-v6`.

Трафик YouTube (видеопотоки, сайт, API, превью) начинает выходить в Google по IPv6.
Остальной трафик не меняется. Может улучшить качество видео, если IPv4-маршрут к
Google загружен/ограничен, а IPv6 идёт через более чистый пиринг (Google отдаёт другой edge).

## Установка и использование (на OUT-сервере)

```bash
curl -fsSL -o /usr/local/sbin/ssb-youtube-v6-patch.sh \
  https://raw.githubusercontent.com/Anton98567/ssb-youtube-v6-patch/main/ssb-youtube-v6-patch.sh \
  && chmod 700 /usr/local/sbin/ssb-youtube-v6-patch.sh

ssb-youtube-v6-patch.sh apply          # применить (IPv6 определится сам)
ssb-youtube-v6-patch.sh status         # состояние
ssb-youtube-v6-patch.sh test           # проверка связности YouTube по IPv6
ssb-youtube-v6-patch.sh remove         # полный откат
```

## Что покрывается (домены YouTube)

Перечислить все хосты невозможно в принципе — видеопотоки идут на динамические
поддомены вида `rr3---sn-4g5edndd.googlevideo.com` (их тысячи и они меняются).
Поэтому используются **суффиксные правила** — они покрывают все поддомены по построению:

| Группа | Правила |
|---|---|
| Видеопотоки, манифесты, live | суффикс `googlevideo.com` |
| Сайт, Shorts, Music, TV, Kids | суффиксы `youtube.com`, `youtu.be`, `youtube-nocookie.com`, `youtubekids.com` |
| API (Innertube и др.) | `youtubei.googleapis.com`, `jnn-pa.googleapis.com`, `youtube.googleapis.com` |
| Превью, аватары | суффиксы `ytimg.com`, `ggpht.com`; `yt3.googleusercontent.com`, `lh3.googleusercontent.com` |

## Безопасность и откат

- перед правкой — бэкап конфига в `/root/bak-singbox/`;
- `sing-box check` после изменений; при ошибке — **авто-откат** из бэкапа;
- после apply — тесты связности (IPv6, DNS AAAA, generate_204, ytimg, gvt1);
  при провале — **авто-откат** и сообщение об ошибке;
- `remove` удаляет outbound и правила целиком.

## Требования

- OUT-сервер с sing-box и рабочим исходящим IPv6 (проверяется тестами автоматически);
- root.

## Идея применения

Если клиенты жалуются на буферизацию YouTube через VPN-туннель: сначала исключить
QUIC-over-тunnel (блокировка UDP/443 на клиенте), затем — этот патч как вариант
улучшения маршрута OUT→Google. Патч не требует изменения клиентских конфигов.
