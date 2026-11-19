# scripts

Сборник скриптов для быстрой настройки Linux-серверов.

## ⭐ Меню — все скрипты в одном

Цветное меню со статусом сервера: выберите один скрипт или сразу несколько (`1 4 5`, `1-3`, `a` — быстрая настройка ноды: swap + IPv6 + ufw + fail2ban). Меню заранее спросит все параметры (Enter — значение по умолчанию), покажет очередь, после подтверждения выполнит в правильном порядке (swap → IPv6 → netplan → ufw → fail2ban) и выведет итог. Скрипты каждый раз скачиваются свежими, весь вывод пишется в `/var/log/jorasssip-scripts/`.

```bash
bash <(curl -fsSL raw.githubusercontent.com/jorasssip/scripts/main/menu.sh)
```

Если вы не root:

```bash
curl -fsSL raw.githubusercontent.com/jorasssip/scripts/main/menu.sh | sudo bash
```

Каждый скрипт можно запускать и отдельно — команды ниже.

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

## Netplan primary IP

Меняет основной исходящий IPv4 на Ubuntu через Netplan policy routing: с бэкапом, проверкой и автоматическим откатом через 180 секунд, если что-то пошло не так. Интерактивно предлагает два действия: 1 — установить/заменить новый основной IPv4, 2 — вернуть исходный единственный IPv4:

```bash
curl -fsSL https://raw.githubusercontent.com/jorasssip/scripts/main/netplan-primary-ip.sh | sudo bash
```

Без вопросов — установить новый основной IPv4 (`NEW_IP` заменить на адрес) или откатиться к исходному:

```bash
curl -fsSL https://raw.githubusercontent.com/jorasssip/scripts/main/netplan-primary-ip.sh | sudo bash -s -- 1 NEW_IP
```

```bash
curl -fsSL https://raw.githubusercontent.com/jorasssip/scripts/main/netplan-primary-ip.sh | sudo bash -s -- 2
```

Подробности — в репозитории [netplan-primary-ip](https://github.com/jorasssip/netplan-primary-ip).

## Автор

[jorasssip](https://github.com/jorasssip). Лицензия: [MIT](LICENSE).
