# Backhaul Installer

نصب‌کننده تعاملی Backhaul برای ساخت و مدیریت چند Tunnel مستقل.

## قابلیت‌ها

- پشتیبانی از چندین Tunnel مستقل (از 1 تا 100 عدد)
- برای هر Tunnel یک سرویس systemd جدا ساخته می‌شود:
  - `backhaul-1.service`
  - `backhaul-2.service`
  - `backhaul-3.service`
  - ...
- کانفیگ هر Tunnel جداست:
  - `/etc/backhaul/server-N.toml`
  - `/etc/backhaul/client-N.toml`
- Tunnelهای مختلف می‌توانند تنظیمات و پورت‌های متفاوت داشته باشند.
- TLS certificate برای سرور در مسیر مشترک `/etc/backhaul/` نگهداری می‌شود.
- امکان Restart، Status، Logs و حذف هر Tunnel به‌صورت جداگانه.
- گزینه حذف کامل تمام Tunnelها، سرویس‌ها، کانفیگ‌ها و باینری.

## نحوه استفاده

```bash
chmod +x install.sh
sudo ./install.sh
```

در اولین استفاده تعداد حداکثر Tunnelها پرسیده می‌شود؛ مقدار پیش‌فرض `10` است و می‌توان عددی بین `1` تا `100` وارد کرد.

بعداً از منوی اصلی گزینه `8) Set Max Tunnels` برای تغییر این مقدار استفاده کن.

### مثال

اگر حداکثر Tunnel را `5` بگذاری، می‌توانی Tunnelهای 1 تا 5 را مستقل نصب و مدیریت کنی.

روی سرور ایران:

- Tunnel 1 → پورت 2053
- Tunnel 2 → پورت 2054
- Tunnel 3 → پورت 2055

و در سرورهای خارج، هر Client را با دامنه/پورت و Token مربوط به همان Tunnel تنظیم کن.

> توجه: تعداد Tunnel قابل ساخت توسط اسکریپت تا 100 است، اما تعداد عملی Tunnelها به CPU، RAM، پهنای‌باند، تعداد اتصال‌ها و پورت‌های آزاد سرور بستگی دارد.

## ساختار فایل‌ها

```text
/etc/backhaul/
├── max-tunnels
├── cert.crt
├── private.key
├── server-1.toml
├── client-1.toml
├── server-2.toml
├── client-2.toml
└── ...

/etc/systemd/system/
├── backhaul-1.service
├── backhaul-2.service
└── ...
```

نسخه Backhaul مورد استفاده به‌صورت پیش‌فرض `v0.7.2` است.


### v4 fix
The client config now uses the entered remote port correctly (`domain:port`); the previous version accidentally reused the domain as the port. Basic domain/IP and port validation was also added.
