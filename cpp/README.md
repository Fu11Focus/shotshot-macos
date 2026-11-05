# ShotShot — C++ варіант (дво-процесний, мінімальна idle-пам'ять)

Мета була: чи можна зменшити пам'ять, як у ClipHistory. Пройшли два етапи.

## Етап 1 — повний Obj-C++ порт (глухий кут за пам'яттю)

`ShotShotCpp.mm` спершу був повним однопроцесним портом `../main.swift`:
той самий менюбар-агент ✂︎ + редактор. Результат:

| ShotShot (1 процес) | бінарник | idle footprint |
|---|---|---|
| Swift | 194 КБ | 14 МБ |
| Obj-C++ | 129 КБ | **13 МБ** |

Виграш лише ~1 МБ: idle-пам'ять тримають **AppKit + ScreenCaptureKit + Metal**,
а не мова. Swift runtime — дрібниця на їхньому тлі. Прибрати AppKit з процесу,
що показує менюбар-іконку й малює редактор, **неможливо** (немає публічного
не-AppKit способу створити вікно/статус-бар).

## Етап 2 — дво-процесний поділ (реальний виграш)

Той самий трюк, що в ClipHistory: винести AppKit із резидентної частини.

- **`shotd.cpp`** → `ShotShotCpp` — резидентний демон, **БЕЗ AppKit**. Лише
  `CGEventTap` на ⌘⇧7 на голому `CFRunLoop`. Лінкує тільки ApplicationServices +
  CoreFoundation + CoreGraphics. На ⌘⇧7 робить `posix_spawn` редактора.
- **`ShotShotCpp.mm`** → `ShotShotCppEditor` — редактор на вимогу. Запускається,
  одразу робить знімок (ScreenCaptureKit), дає анотувати, копіює/зберігає й
  **виходить** (`NSApp terminate`). AppKit тут є, але живе лише кілька секунд.

| ShotShot резидентний процес | idle footprint |
|---|---|
| Swift (1 процес) | 14 МБ |
| Obj-C++ (1 процес) | 13 МБ |
| **C++ демон (поділ)** | **~2.1 МБ** |

Важкий редактор більше не сидить у пам'яті постійно — пік ~256 МБ під час знімка
виникає лише на той час, поки відкрито редактор, і зникає з його виходом.

## Ціна поділу

- **Немає постійної іконки ✂︎ в менюбарі** (демон невидимий). Вийти:
  `launchctl bootout gui/$(id -u)/com.ek.shotshotcpp` або `pkill ShotShotCpp`.
- **Два дозволи**: демону — **Accessibility** (для `CGEventTap`), редактору —
  **Screen Recording** (для ScreenCaptureKit). У Swift-версії хоткей Carbon не
  потребував Accessibility; CGEventTap потребує.
- Крихітна затримка на холодний старт редактора при знімку.

## Збірка та запуск

```bash
./build.sh                 # збирає ShotShotCpp.app (демон + helper-редактор)
open ShotShotCpp.app
```

### Автозапуск (LaunchAgent)

```bash
cp com.ek.shotshotcpp.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ek.shotshotcpp.plist
# зупинка:
launchctl bootout gui/$(id -u)/com.ek.shotshotcpp
```

Запускається через `/usr/bin/open -W` (LaunchServices), щоб `CGEventTap` був
trusted і TCC-грант привʼязувався до bundle id.

### Дозволи — важливо про порядок

`CGEventTap` має створюватись, коли процес **вже** trusted. Тому:
1. Запусти → зʼявиться промпт Accessibility → додай **ShotShotCpp**.
2. **Перезапусти** демон (`launchctl kickstart -k …` або переустанов LaunchAgent) —
   інакше tap лишиться невдалим (`tap=FAILED`). Статус пишеться у `~/.shotd-status`.
3. Перший ⌘⇧7 → редактор попросить Screen Recording → дай і натисни ще раз.

Якщо в списках TCC конфліктують старі записи (той самий bundle id після зміни
ролі бінарника) — скинь: `tccutil reset ScreenCapture com.ek.shotshotcpp` та
`tccutil reset Accessibility com.ek.shotshotcpp`, потім перезапусти й надай наново.

## Висновок

Переписування мовою нічого не дало (~1 МБ). Реальний виграш (14 → ~2 МБ) дала
**зміна архітектури** — винесення важкого UI в окремий on-demand процес, що й було
головним уроком ClipHistory.
