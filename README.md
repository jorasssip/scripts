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

## Автор

[jorasssip](https://github.com/jorasssip). Лицензия: [MIT](LICENSE).
