# Mudi WG Rotation

Скрипт для автоматичної "гарячої заміни" (hot-swap) VPN-профілів WireGuard на роутері GL-iNet Mudi (GL-E750).

## Що робить скрипт
1. **Перемикає WireGuard профілі** по колу (бере список профілів, доданих через веб-інтерфейс).
2. **Відображає статус** на OLED-екрані роутера.

## Встановлення

1. Скопіюйте файли на роутер (через PowerShell):
```powershell
scp -O wg-rotation.sh root@192.168.8.1:/usr/bin/
scp -O wg_rotation_init root@192.168.8.1:/etc/init.d/wg_rotation
```

2. Зайдіть на роутер через SSH та виконайте команди:
```bash
chmod +x /usr/bin/wg-rotation.sh /etc/init.d/wg_rotation
sed -i 's/\r$//' /usr/bin/wg-rotation.sh /etc/init.d/wg_rotation
/etc/init.d/wg_rotation enable
/etc/init.d/wg_rotation start
```

## Налаштування

Після встановлення та запуску служби:
1. Переконайтесь, що у вас додано кілька профілів у розділі **VPN -> WireGuard Client**.
2. Перейдіть в меню **System -> Toggle Button Settings**.
3. У випадаючому списку виберіть **wg_rotation** та натисніть Apply.

## Використання
- Перемкніть боковий тумблер роутера для переходу на наступний VPN-профіль.

## Логи
Перегляд логів роботи сервісу:
```bash
tail -f /var/log/wg_rotation.log
```
