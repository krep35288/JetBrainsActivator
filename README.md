# JB Activate (Windows)

PowerShell-скрипт для активации продуктов JetBrains на Windows через `ja-netfilter` с проверкой всех скачиваемых файлов через VirusTotal.

## ⚠️ Дисклеймер

Проект создан в ознакомительных целях. Автор не несёт ответственности за использование в коммерческих целях или нарушение лицензионного соглашения JetBrains. Если продукт нужен для работы — купите лицензию: https://www.jetbrains.com/community/

---

# 📦 УСТАНОВКА С НУЛЯ

## Шаг 1. Откройте PowerShell

Нажмите `Win + X` → выберите **Windows PowerShell** или **Terminal**.

## Шаг 2. Разрешите запуск скриптов

Скопируйте и вставьте в PowerShell:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
```

## Шаг 3. Создайте папку для скрипта

Скопируйте и вставьте:

```powershell
New-Item -ItemType Directory -Path "$env:USERPROFILE\jb-activate" -Force | Out-Null
Set-Location "$env:USERPROFILE\jb-activate"
```

## Шаг 4. Сохраните скрипт

Откройте Блокнот и создайте файл:

```powershell
notepad .\activate.ps1
```

Блокнот спросит «Создать файл?» — нажмите **Да**. Вставьте в него код скрипта `activate.ps1` (см. раздел «Код скрипта» ниже), сохраните (`Ctrl+S`) и закройте.

## Шаг 5. Создайте файл с ключами VirusTotal

Скопируйте и вставьте:

```powershell
notepad .\vtkeys.txt
```

Блокнот спросит «Создать файл?» — нажмите **Да**. Вставьте ключи (один на строку):

```text
# Пул ключей VirusTotal
# Пустые строки и строки с # игнорируются
# Максимум 50 ключей

30e93850855f043441b1f6f1b50eacc060fff1d7c6ddb68d3bf0aadb5c96ceba
```

Получить ключ: https://www.virustotal.com/gui/my-apikey

Сохраните (`Ctrl+S`) и закройте.

## Шаг 6. Запустите

Скопируйте и вставьте:

```powershell
powershell -ExecutionPolicy Bypass -File .\activate.ps1
```

Скрипт спросит:

1. **Закрыть все JetBrains IDE** и ввести `yes`.
2. **Имя лицензии** — нажмите Enter для `ckey.run`.
3. **Дату окончания** — нажмите Enter для `2099-12-31`.

Дождитесь строки:

```
[..] [OK]   Готово. Бэкапы: C:\Users\<user>\.jb_run\backups
```

Откройте IDE — лицензия должна быть активна.

---

# 🎮 ЗАПУСК В БУДУЩЕМ

Откройте PowerShell и вставьте:

```powershell
Set-Location "$env:USERPROFILE\jb-activate"
powershell -ExecutionPolicy Bypass -File .\activate.ps1
```

Или одной строкой без перехода в папку:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\jb-activate\activate.ps1"
```

---

# ⚙️ ПАРАМЕТРЫ

| Параметр | Описание |
|---|---|
| `-Yes` | Без вопросов, значения по умолчанию |
| `-LicenseName "..."` | Имя лицензии |
| `-ExpiryDate "yyyy-MM-dd"` | Дата окончания |
| `-VtApiKey "..."` | Один VT-ключ |
| `-VtApiKeys @("k1","k2")` | Массив VT-ключей |
| `-SkipVtCheck` | Пропустить проверку VirusTotal (не рекомендую) |

Примеры:

```powershell
# Тихий режим
powershell -ExecutionPolicy Bypass -File .\activate.ps1 -Yes

# Своё имя и дата
powershell -ExecutionPolicy Bypass -File .\activate.ps1 -Yes -LicenseName "my" -ExpiryDate "2099-12-31"

# Один конкретный ключ
powershell -ExecutionPolicy Bypass -File .\activate.ps1 -VtApiKey "30e938..."
```

---

# 🔑 ПУЛ КЛЮЧЕЙ VIRUSTOTAL

Скрипт поддерживает до **50 ключей** с автоматическим переключением. Источники (первый найденный побеждает):

1. Параметр `-VtApiKeys` / `-VtApiKey`
2. `$env:VT_API_KEYS` (через `,` или `;`)
3. `$env:VT_API_KEY`
4. **`vtkeys.txt` рядом со скриптом**
5. `~/.vt_keys`

## Как работает

- Кулдаун **16 секунд** между запросами одним ключом (free tier: 4/мин).
- **401/403** — ключ помечается мёртвым, переключение на следующий.
- **429** — переключение, если есть живые; иначе ожидание 25 секунд.
- В логах только префикс ключа (`...a1b2c3d4`).

## Пропускная способность

| Ключей | Запросов/мин | Время на 13 файлов |
|---|---|---|
| 1 | ~4 | ~7 мин |
| 2 | ~8 | ~3.5 мин |
| 4 | ~16 | ~2 мин |
| 10 | ~40 | ~1 мин |
| 50 | ~200 | ~30 сек |

---

# 📁 СТРУКТУРА ПОСЛЕ ЗАПУСКА

```
C:\Users\<user>\
├── jb-activate\
│   ├── activate.ps1
│   └── vtkeys.txt
├── .jb_run\
│   ├── ja-netfilter.jar
│   ├── config\        (dns.conf, env.conf, native.conf, power.conf, url.conf)
│   ├── plugins\       (dns.jar, env.jar, native.jar, power.jar, url.jar, hideme.jar, privacy.jar)
│   └── backups\       (бэкапы изменённых файлов)
└── AppData\Roaming\JetBrains\
    └── IntelliJIdea2025.1\
        ├── idea64.exe.vmoptions   ← +javaagent
        ├── idea.key               ← сгенерированный ключ
        └── disabled_plugins.txt   ← очищен
```

---

# 🔄 ОТКАТ

Восстановить `.vmoptions` и `disabled_plugins.txt`:

```powershell
$stamp = "20260101_120000"   # метка из лога
Copy-Item "$env:USERPROFILE\.jb_run\backups\$stamp\*" `
          "$env:APPDATA\JetBrains\IntelliJIdea2025.1\" -Force
```

Удалить всё, что создал скрипт:

```powershell
Remove-Item -Recurse -Force "$env:USERPROFILE\.jb_run"
```

---

# 🛡️ БЕЗОПАСНОСТЬ

**Что делает скрипт:**
- TLS 1.2 принудительно
- Проверка magic bytes `PK` у каждого `.jar`
- SHA-256 каждого файла + проверка через VirusTotal
- Отказ при `malicious > 0` или `suspicious > 0`
- Бэкап перед каждой правкой
- Не требует админа, не трогает системные папки, реестр, автозагрузку

**Остаётся риском:**
- VirusTotal не гарантирует 100% чистоту
- Сервер `ckey.run` может отдать другой файл
- `.key` генерируется на стороне сервера
- `ja-netfilter` внедряется в JVM

**Как снизить риски:**
1. Соберите `ja-netfilter` из исходников: https://gitee.com/ja-netfilter/ja-netfilter
2. Запускайте в Windows Sandbox или виртуалке
3. Не отключайте антивирус
4. Ограничьте доступ к `vtkeys.txt`:
   ```powershell
   icacls .\vtkeys.txt /inheritance:r /grant:r "$env:USERNAME:(R)"
   ```

---

# ❓ FAQ

**«выполнение сценариев отключено в этой системе»**
```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
```

**«ключи не найдены»**
Убедитесь, что `vtkeys.txt` в той же папке, что `activate.ps1`:
```powershell
Get-ChildItem "$env:USERPROFILE\jb-activate\vtkeys.txt"
```

**IDE не подхватывает активацию**
1. Проверьте `-javaagent` в `.vmoptions`:
   ```powershell
   Get-Content "$env:APPDATA\JetBrains\IntelliJIdea2025.1\idea64.exe.vmoptions"
   ```
2. Закройте IDE и запустите скрипт заново.

**Ошибка 429 (rate limit)**
Free tier — 4 запроса/мин на ключ. Добавьте ещё ключей в `vtkeys.txt`.

**«Не найдена папка JetBrains»**
Установите и **запустите один раз** любую JetBrains IDE — тогда создастся `%APPDATA%\JetBrains`.

**Файл занят**
Закройте все IDE:
```powershell
Get-Process | Where-Object { $_.Name -match "idea|pycharm|webstorm|goland|clion|rider|phpstorm|rubymine|datagrip|appcode|dataspell|rustrover" } | Stop-Process -Force
```

**Проверить доступ к серверу**
```powershell
Test-NetConnection ckey.run -Port 443
```

---

# 📄 ЛИЦЕНЗИЯ

MIT

# 🙏 БЛАГОДАРНОСТИ

- [ja-netfilter](https://gitee.com/ja-netfilter/ja-netfilter)
- [VirusTotal](https://www.virustotal.com/)
