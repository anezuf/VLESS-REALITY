#!/usr/bin/env bash
# VLESS REALITY / 3x-ui installer — v0.9 — Ubuntu/Debian x86_64, clean VPS
set -Eeuo pipefail
umask 077

say() { printf '\n\033[1;36m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
trap 'warn "Ошибка на строке $LINENO (код $?). Проверь вывод выше; автоматического удаления данных нет."' ERR
[[ $EUID -eq 0 ]] || die 'Запусти через sudo bash install.sh'
[[ $(uname -m) == 'x86_64' ]] || die 'Эта версия поддерживает только x86_64 (amd64)'
[[ -r /etc/os-release ]] || die 'Не удалось определить ОС'
. /etc/os-release
[[ "${ID:-}" == ubuntu || "${ID:-}" == debian ]] || die 'Поддерживаются Ubuntu и Debian'
[[ -r /dev/tty && -w /dev/tty ]] || die 'Нужен интерактивный терминал. Сначала скачай файл, затем запусти sudo bash install.sh'
exec 3<>/dev/tty
ask() {
  local __name="$1" question="$2" def="${3:-}" answer
  if ! IFS= read -r -u 3 -p "$question${def:+ [$def]}: " answer; then die 'Ввод прерван'; fi
  printf -v "$__name" '%s' "${answer:-$def}"
}
valid_domain() { [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ && "$1" == *.* && ${#1} -le 253 && "$1" != *..* ]]; }
valid_ipv4() { python3 - "$1" <<'PY'
import ipaddress,sys
try:
 a=ipaddress.IPv4Address(sys.argv[1]); assert a.is_global
except (ValueError, AssertionError): sys.exit(1)
PY
}
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

say 'VLESS REALITY — автоматическая установка 3x-ui + Nginx'
warn 'Только для чистого VPS. На существующем сервере с VPN/Nginx ничего не переустанавливай.'
for cmd in curl python3 ip ss systemctl getent;  do command -v "$cmd" >/dev/null || die "Не найдена команда $cmd"; done
# --resume is deliberately opt-in. Only supported for an interrupted *initial*
# installation after x-ui was installed, before creating any inbounds.
RESUME=0
if [[ "${1:-}" == '--resume' ]]; then
  RESUME=1
elif [[ $# -gt 0 ]]; then
  die 'Использование: bash install.sh [--resume]'
fi
if (( RESUME )); then
  [[ -r /etc/x-ui/x-ui.db && -x /usr/local/x-ui/bin/xray-linux-amd64 ]] || die 'Нет установленной 3x-ui/Xray для продолжения'
  [[ -f /etc/nginx/nginx.conf ]] || die 'Nginx не установлен; --resume неприменим'
  [[ ! -f /etc/ru-reality/state.json ]] || die 'Предыдущая установка уже создала конфигурацию; --resume запрещён'
  COUNT=$(python3 - <<'PYSQL'
import sqlite3
c=sqlite3.connect('file:/etc/x-ui/x-ui.db?mode=ro',uri=True)
print(c.execute('SELECT count(*) FROM inbounds').fetchone()[0])
PYSQL
  )
  [[ "$COUNT" == 0 ]] || die 'Уже есть inbounds — для безопасности --resume запрещён'
  [[ ! -f /etc/nginx/stream-enabled/ru-reality.conf ]] || die 'Уже есть конфигурация Nginx для RU REALITY; --resume запрещён'
  warn 'Режим --resume: продолжение прерванной установки. Без переустановки 3x-ui и Certbot.'
else
  if systemctl list-unit-files x-ui.service 2>/dev/null | grep -q '^x-ui.service'; then die '3x-ui уже установлена. Для прерванной установки используй --resume.'; fi
  [[ ! -e /etc/x-ui/x-ui.db ]] || die 'Найдена существующая база 3x-ui. Установка отменена.'
  [[ ! -f /etc/nginx/nginx.conf ]] || die 'Nginx уже установлен. Для прерванной установки используй --resume.'
  if ss -lntH '( sport = :80 or sport = :443 or sport = :8443 or sport = :7443 or sport = :9443 or sport = :23307 or sport = :59015 )' 2>/dev/null | grep -q .; then die 'Один из необходимых портов занят.'; fi
fi

ask DOMAIN 'Основной домен REALITY (пример: example.com)'
DOMAIN=${DOMAIN,,}
SUBDOMAIN_DEFAULT="sub.$DOMAIN"
valid_domain "$DOMAIN" || die 'Неверный домен'
ask SUBDOMAIN 'Домен панели и подписок' "$SUBDOMAIN_DEFAULT"
SUBDOMAIN=${SUBDOMAIN,,}
valid_domain "$SUBDOMAIN" || die 'Неверный домен подписок'
[[ "$DOMAIN" != "$SUBDOMAIN" ]] || die 'Домены должны различаться'
ask EU_IP 'Публичный IPv4 EU сервера' "$(ip -4 -o addr show scope global | awk 'NR==1 {split($4,a,"/"); print a[1]}')"
valid_ipv4 "$EU_IP" || die 'Неверный публичный EU IP'
ask EMAIL 'Email для сертификатов Let’s Encrypt'
EMAIL=${EMAIL//[[:space:]]/}
[[ "$EMAIL" =~ ^[A-Za-z0-9][A-Za-z0-9._%+\-]*@[A-Za-z0-9][A-Za-z0-9.\-]*\.[A-Za-z]{2,}$ ]] || die 'Неверный email. Введи адрес латиницей без пробелов'
ask RELAY 'IP RU Relay (оставь пустым, если нет)' ''
if [[ -n "$RELAY" ]]; then valid_ipv4 "$RELAY" || die 'Неверный публичный IPv4 RU Relay'; fi
ask SSH_PORT 'Твой SSH-порт (только для справки, firewall не меняем)' 22
valid_port "$SSH_PORT" || die 'Неверный SSH-порт'

cat >&3 <<EOF

Будет настроено:
  REALITY: $DOMAIN → Nginx :443 → Xray :8443
  TLS Target: https://127.0.0.1:9443
  Панель/подписки: $SUBDOMAIN → Nginx :7443
  Клиентский адрес: ${RELAY:-публичный IP EU сервера}
  WARP: вручную после установки
  Firewall: не изменяем (проверь TCP 80/443 и SSH; IP RU Relay нужно настроить отдельно)

EOF
ask CONFIRM 'На ЧИСТОМ VPS начать установку? Напиши YES' ''
[[ "$CONFIRM" == 'YES' ]] || die 'Отменено'

say 'Проверка DNS и получение сертификата (standalone)'
# ACME HTTP-01 требует доступного снаружи TCP 80 и A-записей на EU IP.
for name in "$DOMAIN" "$SUBDOMAIN"; do
  if ! getent ahostsv4 "$name" | awk '{print $1}' | sort -u | grep -Fxq "$EU_IP"; then
    die "Домен $name не указывает на $EU_IP. Настрой DNS A, отключи CDN/Proxy и повтори установку."
  fi
done
CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
if (( RESUME )); then
  [[ -r "$CERT_DIR/fullchain.pem" && -r "$CERT_DIR/privkey.pem" ]] || die 'Не найдены сертификаты от первой попытки. Проверь введённые домены.'
  # Verify that the existing cert covers the provided domains.
  for name in "$DOMAIN" "$SUBDOMAIN"; do
    openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -ext subjectAltName | grep -Fq "DNS:$name" || die "Сертификат не содержит $name"
  done
  warn 'Найдены существующие сертификаты и пустая 3x-ui, продолжаем.'
else
  if ss -lntH '( sport = :80 )' 2>/dev/null | grep -q .; then
    die 'TCP 80 занят. Для выдачи сертификата standalone порт 80 должен быть свободен.'
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl ca-certificates openssl python3 certbot sqlite3 nginx-common
  certbot certonly --standalone --preferred-challenges http \
    --non-interactive --agree-tos --email "$EMAIL" \
    --cert-name "$DOMAIN" -d "$DOMAIN" -d "$SUBDOMAIN"
  [[ -r "$CERT_DIR/fullchain.pem" && -r "$CERT_DIR/privkey.pem" ]] || die 'Сертификаты не найдены'
  say 'Установка Nginx и stream-модуля'
  apt-get install -y nginx libnginx-mod-stream
  mkdir -p /var/www/html /etc/nginx/stream-enabled /etc/nginx/sites-enabled
  rm -f /etc/nginx/sites-enabled/default
  systemctl stop nginx || true

  say 'Установка официальной 3x-ui'
  TMP_INSTALL=$(mktemp)
  trap 'rm -f "$TMP_INSTALL"' EXIT
  curl -fsSL --retry 3 https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh -o "$TMP_INSTALL"
  XUI_NONINTERACTIVE=1 bash "$TMP_INSTALL"
  [[ -f /etc/x-ui/x-ui.db ]] || die 'Официальный установщик не создал базу SQLite'
  [[ -x /usr/local/x-ui/bin/xray-linux-amd64 ]] || die 'Не найден бинарник Xray для amd64'
fi

# Инициализация криптографических параметров без передачи ключей в чат/лог.
XRAY_BIN=/usr/local/x-ui/bin/xray-linux-amd64
KEYS=$($XRAY_BIN x25519)
PRIVATE_KEY=$(printf '%s\n' "$KEYS" | sed -nE 's/^(Private key|PrivateKey):[[:space:]]*//p' | head -1)
PUBLIC_KEY=$(printf '%s\n' "$KEYS" | sed -nE 's/^(Public key|PublicKey|Password|Password \(PublicKey\)):[[:space:]]*//p' | head -1)
[[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || die 'Не удалось сгенерировать ключи X25519 (неожиданный формат xray x25519)'
SHORT_IDS=$(python3 - <<'PYSHORT'
import secrets
print(','.join(secrets.token_hex(8) for _ in range(8)))
PYSHORT
)
SHORT_ID=${SHORT_IDS%%,*}
CLIENT_UUID=$($XRAY_BIN uuid)
[[ "$CLIENT_UUID" =~ ^[a-f0-9-]{36}$ ]] || die 'Ошибка генерации UUID'
HOST_IP=${RELAY:-$EU_IP}
WS_PORT=$(python3 - <<'PYPORT'
import secrets
print(secrets.randbelow(30000)+20000)
PYPORT
)
TROJAN_PORT=$((WS_PORT+1))
WS_UUID=$($XRAY_BIN uuid)
XHTTP_UUID=$($XRAY_BIN uuid)
TROJAN_PASSWORD=$(openssl rand -hex 20)
WS_PATH=$(openssl rand -hex 8)
GRPC_PATH=$(openssl rand -hex 8)
XHTTP_PATH=$(openssl rand -hex 8)
PANEL_USER="admin$(openssl rand -hex 3)"
PANEL_PASS=$(openssl rand -hex 18)

# Используем SQLite 3x-ui: конфигурация сохраняется в интерфейсе, а не только в config.json.
# Перед изменениями обязательно останавливаем службу и делаем бэкап через SQLite backup API.
systemctl stop x-ui
export DOMAIN SUBDOMAIN CERT_DIR PRIVATE_KEY PUBLIC_KEY SHORT_ID SHORT_IDS CLIENT_UUID HOST_IP EU_IP WS_PORT TROJAN_PORT WS_UUID XHTTP_UUID TROJAN_PASSWORD WS_PATH GRPC_PATH XHTTP_PATH
python3 - <<'PY'
import sqlite3, json, os, time, pathlib, secrets, ipaddress
p='/etc/x-ui/x-ui.db'
c=sqlite3.connect(p)
backup=sqlite3.connect(f'/etc/x-ui/x-ui.db.backup-{int(time.time())}')
c.backup(backup);backup.close()
settings={k:v for k,v in c.execute('SELECT key,value FROM settings')}
# На чистой 3x-ui панель может ещё не создать xrayTemplateConfig.
# Создаём базовый шаблон только при его отсутствии (существующий не затираем).
raw_template=settings.get('xrayTemplateConfig')
if raw_template and raw_template.strip():
 tmpl=json.loads(raw_template)
 if not isinstance(tmpl,dict): raise RuntimeError('Неожиданный Xray template')
 print('Используем существующий шаблон Xray из 3x-ui')
else:
 tmpl={
  'log':{'access':'none','dnsLog':False,'error':'','loglevel':'warning','maskAddress':''},
  'routing':{'domainStrategy':'IPIfNonMatch','rules':[]},
  'outbounds':[],
  'policy':{
   'levels':{'0':{'statsUserDownlink':True,'statsUserOnline':True,'statsUserUplink':True}},
   'system':{'statsInboundDownlink':True,'statsInboundUplink':True,
             'statsOutboundDownlink':False,'statsOutboundUplink':False}
  },
  'stats':{}
 }
 print('Создаём исходный шаблон Xray для новой 3x-ui')
if c.execute('SELECT count(*) FROM inbounds').fetchone()[0]: raise RuntimeError('База уже содержит inbounds')
# Исходящий direct остаётся первым, пока пользователь не создаст WARP MASQUE.
tmpl['outbounds']=[{'tag':'direct','protocol':'freedom','settings':{}}, {'tag':'blocked','protocol':'blackhole','settings':{}}]
tmpl['routing']={'domainStrategy':'IPIfNonMatch','rules':[
 {'type':'field','inboundTag':['api'],'outboundTag':'api'},
 {'type':'field','ip':['geoip:private'],'outboundTag':'blocked'},
 {'type':'field','protocol':['bittorrent'],'outboundTag':'blocked'},
 {'type':'field','domain':['geosite:category-ads-all'],'outboundTag':'blocked'}]}
def setting(k,v):
 # In 3x-ui 3.10.x settings.key is not necessarily UNIQUE.
 # UPDATE-first works for both existing and uninitialized installations.
 value=str(v)
 exists=c.execute('SELECT id FROM settings WHERE key=? LIMIT 1',(k,)).fetchone()
 if exists:
  c.execute('UPDATE settings SET value=? WHERE key=?',(value,k))
 else:
  c.execute('INSERT INTO settings(key,value) VALUES (?,?)',(k,value))
setting('xrayTemplateConfig',json.dumps(tmpl,separators=(',',':')))
# Панель остаётся локальной, но использует собственный TLS-сертификат.
# Эти же пути отображаются в Settings -> Certificates внутри 3x-ui.
setting('webListen','127.0.0.1')
setting('webPort','23307')
setting('webDomain',os.environ['SUBDOMAIN'])
setting('webCertFile',os.path.join(os.environ['CERT_DIR'],'fullchain.pem'))
setting('webKeyFile',os.path.join(os.environ['CERT_DIR'],'privkey.pem'))
base=settings.get('webBasePath','')
if not base or base=='/': base='/'+secrets.token_urlsafe(12)+'/'
if not base.endswith('/'):base+='/'
setting('webBasePath',base)
setting('subEnable','true')
setting('subPort','59015')
setting('subEnableRouting','false')
setting('subCertFile',os.path.join(os.environ['CERT_DIR'],'fullchain.pem'))
setting('subKeyFile',os.path.join(os.environ['CERT_DIR'],'privkey.pem'))
setting('subDomain',os.environ['SUBDOMAIN'])
subpath=settings.get('subURI') or ('/'+secrets.token_urlsafe(10))
jsonpath=settings.get('subJsonURI') or ('/'+secrets.token_urlsafe(10))
setting('subURI',subpath)
setting('subJsonURI',jsonpath)
settings_json={'clients':[{'id':os.environ['CLIENT_UUID'],'flow':'xtls-rprx-vision','email':'user1'}], 'decryption':'none','testseed':[900,500,900,256]}
stream={'network':'tcp','security':'reality','realitySettings':{
 'show':False,'target':'127.0.0.1:9443','xver':0,'serverNames':[os.environ['DOMAIN']],
 'privateKey':os.environ['PRIVATE_KEY'],'shortIds':os.environ['SHORT_IDS'].split(','),
 'settings':{'publicKey':os.environ['PUBLIC_KEY'],'fingerprint':'firefox','serverName':os.environ['DOMAIN'],'spiderX':'/'},
 'minClientVer':'','maxClientVer':'','maxTimediff':0,'mldsa65Seed':''},
 'tcpSettings':{'acceptProxyProtocol':True,'header':{'type':'none'}}}
sniff={'enabled':True,'destOverride':['http','tls'],'routeOnly':True}
cols={r[1] for r in c.execute('PRAGMA table_info(inbounds)')}
required={'user_id','up','down','total','remark','enable','expiry_time','traffic_reset','listen','port','protocol','settings','stream_settings','tag','sniffing'}
if not required|{'share_addr_strategy','share_addr'}<=cols: raise RuntimeError('Нужные поля адреса ссылок отсутствуют в inbounds; установщик рассчитан на 3x-ui 3.10.x')
values={'user_id':1,'up':0,'down':0,'total':0,'remark':'reality','enable':1,'expiry_time':0,'traffic_reset':'never',
 'listen':'127.0.0.1','port':8443,'protocol':'vless',
 'share_addr_strategy':'custom','share_addr':os.environ['HOST_IP'],
 'settings':json.dumps(settings_json),
 'stream_settings':json.dumps(stream),'tag':'in-8443-tcp','sniffing':json.dumps(sniff)}
cols=list(values)
c.execute('INSERT INTO inbounds ('+','.join(cols)+') VALUES ('+','.join('?'*len(cols))+')',[values[x] for x in cols])
inbound_id=c.execute('SELECT last_insert_rowid()').fetchone()[0]
# Hosts: fingerprint firefox и адрес RU Relay доступны для редактирования в UI.
hostcols={r[1] for r in c.execute('PRAGMA table_info(hosts)')}
host={'inbound_id':inbound_id,'remark':'RU Relay' if os.environ['HOST_IP']!=os.environ.get('EU_IP','') else 'Direct EU',
      'address':os.environ['HOST_IP'],'port':443,'security':'same','fingerprint':'firefox','sni':os.environ['DOMAIN'],
      'allow_insecure':0,'mihomo_x25519':0,'sort_order':0}
if not {'inbound_id','address','port','security','fingerprint','sni'} <= hostcols: raise RuntimeError('Неизвестная схема hosts')
host={k:v for k,v in host.items() if k in hostcols}
c.execute('INSERT INTO hosts ('+','.join(host)+') VALUES ('+','.join('?'*len(host))+')',list(host.values()))
# На актуальных версиях 3x-ui клиенты нормализованы. Для несовместимой схемы
# откатываем изменения базы, не оставляя частично настроенный inbound.
clientcols={r[1] for r in c.execute('PRAGMA table_info(clients)')}
if {'uuid','email','flow','enable'} <= clientcols:
 client={'uuid':os.environ['CLIENT_UUID'],'email':'user1','flow':'xtls-rprx-vision','enable':1}
 client={k:v for k,v in client.items() if k in clientcols}
 c.execute('INSERT INTO clients ('+','.join(client)+') VALUES ('+','.join('?'*len(client))+')',list(client.values()))
 client_id=c.execute('SELECT last_insert_rowid()').fetchone()[0]
 linkcols={r[1] for r in c.execute('PRAGMA table_info(client_inbounds)')}
 if {'client_id','inbound_id'} <= linkcols:
  c.execute('INSERT INTO client_inbounds(client_id,inbound_id) VALUES (?,?)',(client_id,inbound_id))
# Дополнительные подключения, как в прежней схеме x-ui-pro.
# WS и Trojan gRPC доступны только через HTTPS/SNI Nginx, XHTTP создаётся выключенным.
def add_inbound(remark,port,protocol,client_settings,stream_settings,tag,enabled=True):
 vals={'user_id':1,'up':0,'down':0,'total':0,'remark':remark,'enable':int(enabled),'expiry_time':0,
       'traffic_reset':'never','listen':'127.0.0.1','port':port,'protocol':protocol,
       'settings':json.dumps(client_settings),'stream_settings':json.dumps(stream_settings),
       'tag':tag,'sniffing':json.dumps({'enabled':False,'destOverride':['http','tls']})}
 vals={k:v for k,v in vals.items() if k in cols_meta}
 keys=list(vals)
 c.execute('INSERT INTO inbounds ('+','.join(keys)+') VALUES ('+','.join('?'*len(keys))+')',[vals[k] for k in keys])
 return c.execute('SELECT last_insert_rowid()').fetchone()[0]
cols_meta={r[1] for r in c.execute('PRAGMA table_info(inbounds)')}
def add_host(iid,remark,protocol):
 data={'inbound_id':iid,'remark':remark,'address':os.environ['SUBDOMAIN'],'port':443,
       'security':'tls','sni':os.environ['SUBDOMAIN'],'sort_order':0,'allow_insecure':0}
 data={k:v for k,v in data.items() if k in hostcols}
 keys=list(data)
 c.execute('INSERT INTO hosts ('+','.join(keys)+') VALUES ('+','.join('?'*len(keys))+')',[data[k] for k in keys])
wsport=int(os.environ['WS_PORT']);tp=int(os.environ['TROJAN_PORT'])
wsid=os.environ['WS_UUID']; xid=os.environ['XHTTP_UUID']
wspath='/'+str(wsport)+'/'+os.environ['WS_PATH']
gpath='/'+str(tp)+'/'+os.environ['GRPC_PATH']
ws=add_inbound('vless-ws',wsport,'vless',{'clients':[{'id':wsid,'email':'ws1'}],'decryption':'none'},
   {'network':'ws','security':'none','wsSettings':{'path':wspath,'host':os.environ['SUBDOMAIN'],'headers':{}}},
   'inbound-'+str(wsport))
add_host(ws,'WebSocket','vless')
trojan=add_inbound('trojan-grpc',tp,'trojan',
    {'clients':[{'password':os.environ['TROJAN_PASSWORD'],'email':'trojan1'}],'fallbacks':[]},
    {'network':'grpc','security':'none','grpcSettings':{'authority':os.environ['SUBDOMAIN'],'serviceName':gpath,'multiMode':False}},
    'inbound-'+str(tp))
add_host(trojan,'Trojan gRPC','trojan')
xhttp=add_inbound('vless-xhttp-disabled',0,'vless',
    {'clients':[{'id':xid,'email':'xhttp1'}],'decryption':'none'},
    {'network':'xhttp','security':'none','xhttpSettings':{'path':'/'+os.environ['XHTTP_PATH'],'mode':'packet-up'}},
    'inbound-xhttp-disabled',False)
# Регистрация клиентов в новой нормализованной схеме панели.
if {'uuid','email','flow','enable'} <= clientcols:
 for cid,email,inb in [(wsid,'ws1',ws),(xid,'xhttp1',xhttp)]:
  cl={'uuid':cid,'email':email,'flow':'','enable':1}
  keys=list(cl)
  c.execute('INSERT INTO clients ('+','.join(keys)+') VALUES ('+','.join('?'*len(keys))+')',[cl[k] for k in keys])
  if {'client_id','inbound_id'} <= linkcols:
   c.execute('INSERT INTO client_inbounds(client_id,inbound_id) VALUES (?,?)',(c.execute('SELECT last_insert_rowid()').fetchone()[0],inb))
 if 'password' in clientcols:
  cl={'password':os.environ['TROJAN_PASSWORD'],'email':'trojan1','flow':'','enable':1}
  keys=list(cl)
  c.execute('INSERT INTO clients ('+','.join(keys)+') VALUES ('+','.join('?'*len(keys))+')',[cl[k] for k in keys])
  if {'client_id','inbound_id'} <= linkcols:
   c.execute('INSERT INTO client_inbounds(client_id,inbound_id) VALUES (?,?)',(c.execute('SELECT last_insert_rowid()').fetchone()[0],trojan))
c.commit()
path=pathlib.Path('/etc/ru-reality');path.mkdir(mode=0o700,exist_ok=True)
(path/'state.json').write_text(json.dumps({'domain':os.environ['DOMAIN'],'subdomain':os.environ['SUBDOMAIN'], 'panel_path':base,
 'subscription_path':subpath,'json_path':jsonpath,'public_key':os.environ['PUBLIC_KEY'],'short_id':os.environ['SHORT_ID'],
 'client_uuid':os.environ['CLIENT_UUID'],'host_ip':os.environ['HOST_IP'],
 'ws_port':wsport,'trojan_port':tp,'ws_path':wspath,'grpc_path':gpath},indent=2))
os.chmod(path/'state.json',0o600)
c.close()
PY

# Готовая ссылка REALITY с внешним портом 443, независимо от кнопки Export inbound.
# В версиях 3x-ui прямой экспорт inbound иногда игнорирует порт из Hosts.
python3 - <<'PYLINK'
import json, pathlib, urllib.parse, os
s=json.load(open('/etc/ru-reality/state.json'))
params={'type':'tcp','encryption':'none','security':'reality',
        'pbk':s['public_key'],'fp':'firefox','sni':s['domain'],
        'sid':s['short_id'],'spx':'/','flow':'xtls-rprx-vision'}
link='vless://'+s['client_uuid']+'@'+s['host_ip']+':443?'+urllib.parse.urlencode(params)+'#reality'
out=pathlib.Path('/etc/ru-reality/client-vless.txt');out.write_text(link+'\n');os.chmod(out,0o600)
PYLINK

# Учётные данные задаются через собственную команду 3x-ui, а не прямой правкой users.
# В случае ошибки останавливаем установку, чтобы не выдавать неверный пароль.
/usr/local/x-ui/x-ui setting -username "$PANEL_USER" -password "$PANEL_PASS" -port 23307 -webBasePath "$(python3 -c 'import json;print(json.load(open("/etc/ru-reality/state.json"))["panel_path"])')" >/dev/null \
  || die 'Не удалось установить логин и пароль 3x-ui'
# Настраиваем сертификаты самой панели через штатную команду x-ui, как в 3x-ui-pro.
# Пути указывают на автоматически обновляемые сертификаты Let's Encrypt.
/usr/local/x-ui/x-ui cert \
  -webCert "$CERT_DIR/fullchain.pem" \
  -webCertKey "$CERT_DIR/privkey.pem" >/dev/null \
  || die 'Не удалось зарегистрировать SSL-сертификат в настройках 3x-ui'
# Проверяем фактическую запись в панели до первого запуска Nginx.
python3 - "$CERT_DIR" <<'PY_CERT_VERIFY'
import sqlite3,sys
cert=sys.argv[1]
db=sqlite3.connect('file:/etc/x-ui/x-ui.db?mode=ro',uri=True)
s=dict(db.execute('SELECT key,value FROM settings WHERE key IN ("webCertFile", "webKeyFile")'))
if s.get('webCertFile') != cert+'/fullchain.pem' or s.get('webKeyFile') != cert+'/privkey.pem':
    raise SystemExit('ERROR: Пути сертификатов не сохранились в настройках панели')
print('PASS: SSL-сертификаты настроены в самой 3x-ui')
PY_CERT_VERIFY
printf 'PANEL_USERNAME=%q\nPANEL_PASSWORD=%q\n' "$PANEL_USER" "$PANEL_PASS" > /etc/x-ui/install-result.env
chmod 600 /etc/x-ui/install-result.env

say 'Создание Nginx stream и HTTPS'
# Nginx на Ubuntu поставляет stream-модуль отдельным пакетом.
if ! grep -qF 'include /etc/nginx/stream-enabled/*.conf;' /etc/nginx/nginx.conf; then
  cat >> /etc/nginx/nginx.conf <<'EOF'

stream {
    include /etc/nginx/stream-enabled/*.conf;
}
EOF
fi
cat > /etc/nginx/stream-enabled/ru-reality.conf <<EOF
map \$ssl_preread_server_name \$relay_target {
    hostnames;
    $SUBDOMAIN subscription_backend;
    default reality_backend;
}
upstream reality_backend { server 127.0.0.1:8443; }
upstream subscription_backend { server 127.0.0.1:7443; }
server {
    listen 443;
    listen [::]:443;
    ssl_preread on;
    proxy_protocol on;
    proxy_pass \$relay_target;
}
EOF
cat > /etc/nginx/sites-available/ru-reality-https <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN $SUBDOMAIN;
    return 404;
}
server {
    listen 127.0.0.1:9443 ssl;
    server_name $DOMAIN;
    ssl_certificate $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;
    root /var/www/html;
    location / { try_files \$uri \$uri/ =404; }
}
server {
    listen 127.0.0.1:7443 ssl http2 proxy_protocol;
    server_name $SUBDOMAIN;
    ssl_certificate $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;
    location / { return 404; }
    # Managed endpoint routes follow below.
EOF
python3 - <<'PY' >> /etc/nginx/sites-available/ru-reality-https
import json
s=json.load(open('/etc/ru-reality/state.json'))
base=s['panel_path']
for path,backend in [(base,'https://127.0.0.1:23307'),(s['subscription_path'],'https://127.0.0.1:59015'),(s['json_path'],'https://127.0.0.1:59015')]:
 if not path.startswith('/'):path='/'+path
 # prefix match without rewriting original path
 print('    location ^~ '+path.rstrip('/')+'/ {')
 print('        proxy_set_header Host $host;')
 print('        proxy_set_header X-Forwarded-Proto https;')
 print('        proxy_set_header X-Real-IP $remote_addr;')
 print('        proxy_pass '+backend+';')
 print('        proxy_ssl_server_name on;')
 print('        proxy_ssl_name '+s['subdomain']+';')
 print('        proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;')
 print('        proxy_ssl_verify on;')
 print('    }')
 print('    location = '+path.rstrip('/')+' { return 301 '+path.rstrip('/')+'/; }')
PY
# Только заданные маршруты WS/gRPC. Не используем динамический прокси к произвольным портам.
python3 - <<'PYNGINX' >> /etc/nginx/sites-available/ru-reality-https
import json
s=json.load(open('/etc/ru-reality/state.json'))
ws=s['ws_path']; g=s['grpc_path'];wp=s['ws_port'];gp=s['trojan_port']
print('    location ^~ '+ws+' {')
print('        proxy_http_version 1.1;')
print('        proxy_set_header Upgrade $http_upgrade;')
print('        proxy_set_header Connection "upgrade";')
print('        proxy_set_header Host $host;')
print('        proxy_pass http://127.0.0.1:'+str(wp)+';')
print('    }')
print('    location ^~ '+g+' {')
print('        grpc_set_header Host $host;')
print('        grpc_pass grpc://127.0.0.1:'+str(gp)+';')
print('    }')
PYNGINX
cat >> /etc/nginx/sites-available/ru-reality-https <<'EOF'
}
EOF
ln -sf /etc/nginx/sites-available/ru-reality-https /etc/nginx/sites-enabled/ru-reality-https
# Certbot standalone при продлении должен временно освобождать TCP 80.
# Хуки создаются после первой выдачи и запускаются certbot renew автоматически.
mkdir -p /etc/letsencrypt/renewal-hooks/{pre,post,deploy}
cat > /etc/letsencrypt/renewal-hooks/pre/ru-reality-stop-nginx <<'EOF'
#!/bin/sh
/bin/systemctl stop nginx
EOF
cat > /etc/letsencrypt/renewal-hooks/post/ru-reality-start-nginx <<'EOF'
#!/bin/sh
/bin/systemctl start nginx
EOF
cat > /etc/letsencrypt/renewal-hooks/deploy/ru-reality-xui <<'EOF'
#!/bin/sh
/bin/systemctl restart x-ui
EOF
chmod 755 /etc/letsencrypt/renewal-hooks/{pre/ru-reality-stop-nginx,post/ru-reality-start-nginx,deploy/ru-reality-xui}
systemctl enable --now certbot.timer 2>/dev/null || true
nginx -t
systemctl enable --now nginx
systemctl enable --now x-ui
systemctl restart x-ui
systemctl reload nginx
if ! systemctl is-active --quiet x-ui; then die '3x-ui не запустилась. Проверь journalctl -u x-ui'; fi
if ! systemctl is-active --quiet nginx; then die 'Nginx не запустился'; fi

say 'Проверка сохранённых настроек и доступности сервисов'
python3 - <<'PYVERIFY'
import json,sqlite3,os,sys
s=json.load(open('/etc/ru-reality/state.json'))
c=sqlite3.connect('file:/etc/x-ui/x-ui.db?mode=ro',uri=True)
c.row_factory=sqlite3.Row
r=c.execute("SELECT * FROM inbounds WHERE remark='reality' LIMIT 1").fetchone()
assert r is not None, 'Не создан REALITY inbound'
assert r['share_addr_strategy']=='custom', 'Стратегия клиентского адреса не custom'
assert r['share_addr']==s['host_ip'], 'Адрес клиента в inbound неправильный'
h=c.execute('SELECT * FROM hosts WHERE inbound_id=? LIMIT 1',(r['id'],)).fetchone()
assert h is not None, 'Не создан Host'
assert h['address']==s['host_ip'] and int(h['port'])==443, 'Неправильные IP/порт Host'
assert h['fingerprint']=='firefox', 'Fingerprint в Host отличается от firefox'
print('PASS: Inbound custom address:',r['share_addr'])
print('PASS: Host:',h['address'],h['port'],'fingerprint='+h['fingerprint'])
PYVERIFY
# Xray может стартовать чуть позже systemd — проверяем с ожиданием.
for port in 443 8443 9443 7443 23307; do
  ready=0
  for attempt in {1..20}; do
    if ss -lntH | awk '{print $4}' | grep -Eq ":${port}$"; then ready=1; break; fi
    sleep 1
  done
  (( ready )) || die "Порт $port не прослушивается. См. journalctl -u x-ui и nginx -t"
done
"$XRAY_BIN" run -test -c /usr/local/x-ui/bin/config.json >/dev/null 2>&1 || die 'Конфигурация Xray не проходит проверку'
# Проверяем TLS не только по порту: панель должна реально отдавать HTTPS
# с сертификатом, подходящим для SUBDOMAIN; Nginx — проксировать его через :443.
PANEL_PATH=$(python3 -c 'import json;print(json.load(open("/etc/ru-reality/state.json"))["panel_path"])')
for endpoint in "https://${SUBDOMAIN}:23307${PANEL_PATH}" "https://${SUBDOMAIN}${PANEL_PATH}"; do
  if ! curl --noproxy '*' -fsSL --max-time 12 --resolve "${SUBDOMAIN}:$( [[ "$endpoint" == *":23307"* ]] && echo 23307 || echo 443 ):127.0.0.1" "$endpoint" -o /dev/null; then
    die "HTTPS-проверка не пройдена: $endpoint. Проверь сертификат панели и nginx error.log"
  fi
done
say 'PASS: HTTPS самой панели и Nginx :443'
# Проверка данных экспорта до объявления успеха.
python3 - <<'PYVERIFY2'
import sqlite3,json
c=sqlite3.connect('file:/etc/x-ui/x-ui.db?mode=ro',uri=True)
r=c.execute("SELECT stream_settings FROM inbounds WHERE remark='reality'").fetchone()
d=json.loads(r[0])['realitySettings']['settings']
assert d.get('publicKey') and d.get('fingerprint')=='firefox', 'В REALITY отсутствует публичный ключ либо fingerprint'
assert c.execute('SELECT count(*) FROM inbounds').fetchone()[0] == 4, 'Не все inbounds созданы'
print('PASS: REALITY publicKey/fingerprint; 4 inbounds')
PYVERIFY2

say 'ГОТОВО — базовая установка без WARP'
python3 - <<'PY'
import json
s=json.load(open('/etc/ru-reality/state.json'))
print('Панель: https://'+s['subdomain']+s['panel_path'])
print('Адрес клиента: '+s['host_ip']+':443')
print('SNI: '+s['domain'])
print('Fingerprint: firefox')
print('Готовая ссылка клиента: sudo cat /etc/ru-reality/client-vless.txt (секрет!)')
print('Данные REALITY сохранены: /etc/ru-reality/state.json (только root)')
print('Учётные данные: проверь вывод официального установщика или команду x-ui (сброс логина/пароля).')
PY
if [[ -s /etc/x-ui/install-result.env ]]; then
  warn 'Учётные данные, созданные установщиком: sudo cat /etc/x-ui/install-result.env (не отправляй их никому)'
fi
say 'Сертификаты HTTPS прописаны непосредственно в панели 3x-ui (Settings -> Certificates).'
warn 'WARP MASQUE вручную в 3x-ui → Xray Settings → Outbounds. После регистрации настрой маршрутизацию по умолчанию.'
warn 'v0.9 (тестовая): WS/gRPC созданы, XHTTP выключен. Веб-страница подписок и sub2sing-box ещё не устанавливаются.'
warn 'Обязательно проверь клиентскую ссылку REALITY, соединение через RU Relay и дополнительные протоколы перед продакшеном.'
