# ANEZUF — VLESS REALITY

Автоматическая установка VPN на базе **3x-ui, Xray REALITY и Nginx** с поддержкой RU Relay и Cloudflare WARP.

## 1. Обновление сервера

Выполнить на чистом EU VPS под `root`:

```bash
apt update && apt upgrade -y && apt install -y curl
```

## 2. Установка VPN

```bash
curl -fsSL https://raw.githubusercontent.com/anezuf/VLESS-REALITY/main/install.sh -o install.sh
bash install.sh
```

После запуска указать домены, EU IP и, при необходимости, RU Relay IP.

После успешной установки появится экран **ANEZUF** с адресом панели, логином, паролем и готовой VLESS REALITY-ссылкой.

## 3. Полное удаление

```bash
curl -fsSL https://raw.githubusercontent.com/anezuf/VLESS-REALITY/main/install.sh -o install.sh
bash install.sh --uninstall --purge-packages
```

Для подтверждения ввести `DELETE`.

**Очистка после неудачной установки:**

```bash
bash install.sh --uninstall --purge-packages --clean-orphan-nginx
```

Последний режим использовать только на выделенном VPS без сторонних сайтов.

## 4. Настройка Cloudflare WARP

После успешной установки REALITY открыть панель 3x-ui.

1. Перейти в **Настройки Xray → Исходящие соединения (Outbounds)**.
2. Открыть раздел **WARP** и выбрать регистрацию через **MASQUE**.
3. Зарегистрировать WARP и добавить исходящее соединение с тегом `warp-masque`.
4. Назначить `warp-masque` исходящим соединением по умолчанию, сохранив необходимые исключения в маршрутизации.
5. Сохранить настройки и перезапустить Xray через панель.

**Рекомендуемая маршрутизация:**

| Трафик | Outbound |
|---|---|
| `geoip:ru` | `direct` |
| `domain:ru`, `domain:su`, `domain:xn--p1ai` | `direct` |
| `geosite:category-ads-all` | `blocked` |
| `geoip:private` | `blocked` |
| `bittorrent` | `blocked` |
| Остальной интернет | `warp-masque` |

Правила исключений должны располагаться выше завершающего правила WARP.

## 5. Дополнительные команды

**Открыть меню управления 3x-ui:**

```bash
x-ui
```

**Обновить локальный установщик с GitHub:**

```bash
curl -fsSL https://raw.githubusercontent.com/anezuf/VLESS-REALITY/main/install.sh -o install.sh
```

**Сбросить старый SSH-ключ сервера (на своём компьютере):**

```bash
ssh-keygen -R <IP_сервера>
```

Использовать после переустановки VPS, предварительно убедившись, что изменение ключа ожидаемо.

---

## Информация о конфигурации

Установщик автоматически настраивает:

| Параметр | Значение |
|---|---|
| Protocol | VLESS |
| Network | TCP |
| Security | REALITY |
| Flow | `xtls-rprx-vision` |
| Inbound Port | `8443` |
| External Port | `443` |
| REALITY Target | `127.0.0.1:9443` |
| Fingerprint | `firefox` |
| Routing Strategy | `IPIfNonMatch` |
| SSL | Let's Encrypt |

**RU Relay:** клиент подключается к RU IP по порту `443`. На EU-сервере Nginx передаёт REALITY-соединение внутреннему Xray на `8443`.

**WARP:** регистрируется отдельно через панель 3x-ui. До его включения VPN использует прямое исходящее соединение EU-сервера.

**Важно:** установщик предназначен для чистого VPS. Удаление необратимо. При частых переустановках Let's Encrypt может временно ограничивать повторный выпуск сертификатов для тех же доменов.
