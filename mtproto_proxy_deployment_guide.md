# MTProto Proxy Deployment Guide

**Official telegrammessenger/proxy**  
OS: Ubuntu / Debian  
Port: 9444  
Runtime: Docker

------------------------------------------------------------------------

## 1. System Update

``` bash
sudo apt update && sudo apt upgrade -y
```

------------------------------------------------------------------------

## 2. Install Docker

``` bash
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
systemctl enable docker
systemctl start docker
docker --version
```

------------------------------------------------------------------------

## 3. Generate Secret (HEX)

``` bash
openssl rand -hex 16
```

Save the generated 32-character HEX string.

------------------------------------------------------------------------

## 4. Open Port 9444 (if UFW enabled)

``` bash
sudo ufw allow 9444/tcp
sudo ufw reload
sudo ufw status
```

Also open TCP 9444 in VPS provider firewall panel if applicable.

------------------------------------------------------------------------

## 5. Run MTProto Proxy

``` bash
docker run -d   --name mtproto_proxy   --restart unless-stopped   -p 9444:443   -e SECRET=YOUR_HEX_SECRET   telegrammessenger/proxy
```

Example:

``` bash
docker run -d   --name mtproto_proxy   --restart unless-stopped   -p 9444:443   -e SECRET=590615e578f1fd628069d981ca9c9557   telegrammessenger/proxy
```

------------------------------------------------------------------------

## 6. Verify Container

``` bash
docker ps
```

Expected output:

    0.0.0.0:9444->443/tcp

------------------------------------------------------------------------

## 7. Check Logs

``` bash
docker logs mtproto_proxy
```

Should show:

    Using the explicitly passed secret
    Starting proxy...

------------------------------------------------------------------------

## 8. Get Public IP

``` bash
curl ifconfig.me
```

------------------------------------------------------------------------

## 9. Register in @MTProxybot

    /newproxy

Enter:

    YOUR_IP:9444
    YOUR_HEX_SECRET

------------------------------------------------------------------------

## 10. Connect via Telegram

    https://t.me/proxy?server=YOUR_IP&port=9444&secret=YOUR_HEX_SECRET

------------------------------------------------------------------------

## 11. Diagnostics (Optional)

Check listening port:

``` bash
ss -tulpn | grep 9444
```

Active connections:

``` bash
ss -tnp | grep 9444
```

Live logs:

``` bash
docker logs -f mtproto_proxy
```

------------------------------------------------------------------------

## 12. Update Proxy

``` bash
docker pull telegrammessenger/proxy
docker rm -f mtproto_proxy

docker run -d   --name mtproto_proxy   --restart unless-stopped   -p 9444:443   -e SECRET=YOUR_HEX_SECRET   telegrammessenger/proxy
```

------------------------------------------------------------------------

## 13. Remove Proxy

``` bash
docker rm -f mtproto_proxy
```
