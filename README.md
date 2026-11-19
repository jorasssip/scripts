# scripts

Сборник скриптов для быстрой настройки Linux-серверов.

## Swapfile

Создаёт и включает swap-файл на 2048 МБ:

```bash
bash <(curl -fsSL raw.githubusercontent.com/jorasssip/scripts/main/swapfile.sh) --enable --size 2048
```

## fail2ban

Защита SSH от перебора паролей: бан после 2 неудачных попыток на 30 дней, повторные нарушители банятся всё дольше (до года):

```bash
bash <(curl -fsSL raw.githubusercontent.com/jorasssip/scripts/main/fail2ban.sh) --maxretry 2 --bantime 30d
```

## IPv6

Отключает IPv6 (настройка сохраняется после перезагрузки). Чтобы включить обратно, замените `off` на `on`:

```bash
bash <(curl -fsSL raw.githubusercontent.com/jorasssip/scripts/main/ipv6.sh) off
```

## ufw

Файрвол для ноды (только IPv4): весь входящий трафик закрыт, исходящий открыт. Открыты SSH и 443/tcp для всех, а порт ноды 3001/tcp — только для IP панели. Скрипт спросит IP панели, сам установит ufw/sudo, найдёт порт SSH и не даст отрезать текущую SSH-сессию:

```bash
bash <(curl -fsSL raw.githubusercontent.com/jorasssip/scripts/main/ufw.sh)
```

Без вопросов (несколько панелей — через запятую, порт ноды меняется флагом `--node-port`):

```bash
bash <(curl -fsSL raw.githubusercontent.com/jorasssip/scripts/main/ufw.sh) --panel-ip 203.0.113.10 --yes
```

Важно: при каждом запуске все старые правила ufw сбрасываются (ufw сохраняет их копию в `/etc/ufw/*.rules.<дата>`). Docker обходит ufw: порты, опубликованные через `-p`, будут открыты всем — скрипт предупредит об этом.

## Автор

[jorasssip](https://github.com/jorasssip). Лицензия: [MIT](LICENSE).
