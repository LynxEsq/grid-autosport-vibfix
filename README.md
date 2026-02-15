# GRID Autosport — Xbox Controller Vibration Fix (macOS)

**[Русская версия ниже / Russian version below](#ru)**

Enables Xbox controller vibration (rumble) in GRID Autosport on macOS. The macOS port by Feral Interactive has full force feedback code for steering wheels but no vibration support for Xbox gamepads. This fix adds telemetry-driven vibration with 6 distinct effects.

## Vibration Effects

| Effect | Description | Motor |
|--------|-------------|-------|
| Impact | Crashes, car contacts, wall hits | Both (heavy) |
| Surface | Road roughness, curbs, gravel | Both |
| Cornering | Lateral G-force in turns | Both (subtle) |
| Wheel Slip | Skidding, spinning, lock-up | Right (light) |
| Engine | High RPM rumble | Right (light) |
| Braking | Brake pedal feedback | Left (heavy) |

## Requirements

- macOS 13.0+ (Apple Silicon with Rosetta 2, or Intel)
- GRID Autosport (Feral Interactive macOS port)
- Xbox controller connected via Bluetooth:
  - Xbox Elite Series 2
  - Xbox One S
  - Xbox Series X|S
  - Xbox Adaptive Controller

## Quick Start (Pre-built Binaries)

1. Download or clone this repository:
   ```bash
   git clone https://github.com/renatakmalov/grid-autosport-vibfix.git
   cd grid-autosport-vibfix
   ```

2. Make the launch script executable:
   ```bash
   chmod +x run.sh
   ```

3. Connect your Xbox controller via Bluetooth.

4. Launch the game:
   ```bash
   ./run.sh
   ```

The controller should vibrate briefly on startup (test pulse). Start a race and enjoy the vibration feedback.

## What `run.sh` Does

- Builds the dylib if not already built
- Patches the game's telemetry config (`hardware_settings_config.xml`):
  - Sets telemetry IP to `127.0.0.1` (localhost)
  - Sets `extradata=3` (maximum telemetry data)
  - Sets `delay=0` (minimum latency)
- Launches the game with `DYLD_INSERT_LIBRARIES` to inject the vibration fix
- Stops controller vibration after the game exits

## Configuration

All settings are in `config.txt` (same directory as the dylib). Changes take effect on next game restart.

### Strength Settings

Values are percentages: `100` = default, `50` = half strength, `200` = double, `0` = disabled.

```ini
overall_strength = 100        # Global multiplier for all effects
impact_strength = 100         # Crash/hit intensity
surface_strength = 100        # Road roughness intensity
cornering_strength = 100      # Turn force feedback
slip_strength = 100           # Wheel slip/skid
engine_strength = 100         # Engine vibration
brake_strength = 100          # Brake feedback
```

### Other Settings

```ini
impact_hold = 85              # How long impact sustains (0=instant, 99=very long)
test_on_start = true          # Test vibration when controller detected
dead_zone = 3                 # Motor values below this are zeroed (0-10)
log_telemetry = false         # Enable detailed telemetry logging (for debugging)
```

### Advanced Thresholds

Uncomment these in `config.txt` to fine-tune detection sensitivity:

| Setting | Default | Description |
|---------|---------|-------------|
| `impact_delta_threshold` | `0.7` | G-force spike sensitivity. Lower = more sensitive to car contacts |
| `impact_abs_threshold` | `5.0` | Absolute G-force for wall crashes |
| `surface_threshold` | `60` | Suspension velocity threshold. Lower = more road feel |
| `engine_rpm_threshold` | `4000` | RPM to start engine rumble |
| `slip_threshold` | `3.0` | Wheel slip detection threshold |

## Building from Source

Requires Xcode Command Line Tools.

```bash
# Install Xcode CLT (if not installed)
xcode-select --install

# Build (must be x86_64 for Rosetta 2)
make clean && make all
```

This produces:
- `grid_vibfix.dylib` — the vibration fix library (x86_64)
- `stop_rumble` — utility to stop controller vibration

## How It Works

1. **DYLD injection**: The dylib is loaded into the game process via `DYLD_INSERT_LIBRARIES` (works because the game binary is unsigned x86_64 running under Rosetta 2)

2. **Controller discovery**: Uses IOKit `IOHIDManager` to find Xbox controllers by Vendor ID (`045E`) and Product ID

3. **Telemetry capture**: Listens on UDP port `20777` for EGO engine telemetry (Codemasters format — 66 floats at 30 Hz)

4. **Effect generation**: Parses telemetry data (G-forces, suspension velocity, wheel speeds, RPM, brake/throttle) and generates 6 vibration effects

5. **HID rumble output**: Sends Xbox Bluetooth HID reports (Report ID `0x03`, 9 bytes) with motor values 0-100

6. **Cleanup**: Watchdog thread zeros motors when telemetry stops; `stop_rumble` utility runs after game exit

## Troubleshooting

| Problem | Solution |
|---------|----------|
| No vibration at all | Check that controller is connected via Bluetooth (not USB). Check `grid_vibfix.log` for errors |
| No test vibration on start | Set `test_on_start = true` in `config.txt`. Check log for "Xbox controller found" |
| Vibration too strong/weak | Adjust `overall_strength` or individual effect strengths in `config.txt` |
| Vibration on straights | Lower `engine_strength` or raise `engine_rpm_threshold` |
| Crashes not felt | Raise `impact_strength` (e.g. `150`) or lower `impact_delta_threshold` (e.g. `0.5`) |
| Vibration persists in menus | Should auto-stop within ~1 second. If not, `stop_rumble` runs on game exit |
| "bind() to port 20777 failed" | Another process is using port 20777. Close other telemetry apps |
| Game doesn't launch | Check that the game is installed at `/Applications/GRID Autosport/` |

## Files

| File | Description |
|------|-------------|
| `grid_vibfix.m` | Main dylib source — telemetry parser + vibration generator |
| `grid_vibfix.dylib` | Pre-built dylib (x86_64) |
| `stop_rumble.m` | Utility to zero controller motors |
| `stop_rumble` | Pre-built stop_rumble (x86_64) |
| `config.txt` | User-editable vibration settings |
| `run.sh` | Launch script (patches config + injects dylib) |
| `Makefile` | Build rules |
| `grid_vibfix.log` | Runtime log (created on game start) |

## License

MIT

---

<a name="ru"></a>

# GRID Autosport — Исправление вибрации Xbox-контроллера (macOS)

Включает вибрацию (rumble) Xbox-контроллера в GRID Autosport на macOS. Порт Feral Interactive имеет полный код force feedback для рулей, но не поддерживает вибрацию для Xbox-геймпадов. Этот фикс добавляет вибрацию на основе телеметрии с 6 различными эффектами.

## Эффекты вибрации

| Эффект | Описание | Мотор |
|--------|----------|-------|
| Удар | Столкновения, контакт с машинами, удары о стены | Оба (сильный) |
| Поверхность | Неровности дороги, бордюры, гравий | Оба |
| Повороты | Боковые перегрузки в поворотах | Оба (слабый) |
| Занос | Скольжение, вращение, блокировка колёс | Правый (лёгкий) |
| Двигатель | Вибрация на высоких оборотах | Правый (лёгкий) |
| Торможение | Обратная связь от педали тормоза | Левый (сильный) |

## Требования

- macOS 13.0+ (Apple Silicon с Rosetta 2 или Intel)
- GRID Autosport (порт Feral Interactive для macOS)
- Xbox-контроллер, подключённый по Bluetooth:
  - Xbox Elite Series 2
  - Xbox One S
  - Xbox Series X|S
  - Xbox Adaptive Controller

## Быстрый старт (готовые бинарники)

1. Скачайте или клонируйте репозиторий:
   ```bash
   git clone https://github.com/renatakmalov/grid-autosport-vibfix.git
   cd grid-autosport-vibfix
   ```

2. Сделайте скрипт запуска исполняемым:
   ```bash
   chmod +x run.sh
   ```

3. Подключите Xbox-контроллер по Bluetooth.

4. Запустите игру:
   ```bash
   ./run.sh
   ```

Контроллер должен коротко завибрировать при запуске (тестовый импульс). Начните гонку и наслаждайтесь вибрацией.

## Что делает `run.sh`

- Собирает dylib, если ещё не собран
- Патчит конфиг телеметрии игры (`hardware_settings_config.xml`):
  - Устанавливает IP телеметрии на `127.0.0.1` (localhost)
  - Устанавливает `extradata=3` (максимум данных телеметрии)
  - Устанавливает `delay=0` (минимальная задержка)
- Запускает игру с `DYLD_INSERT_LIBRARIES` для инъекции фикса вибрации
- Останавливает вибрацию контроллера после выхода из игры

## Настройка

Все настройки находятся в файле `config.txt` (в той же директории, что и dylib). Изменения вступают в силу при следующем запуске игры.

### Настройки силы

Значения в процентах: `100` = по умолчанию, `50` = в два раза слабее, `200` = в два раза сильнее, `0` = отключено.

```ini
overall_strength = 100        # Общий множитель для всех эффектов
impact_strength = 100         # Сила ударов/столкновений
surface_strength = 100        # Сила вибрации от поверхности
cornering_strength = 100      # Сила обратной связи в поворотах
slip_strength = 100           # Сила вибрации от заноса
engine_strength = 100         # Сила вибрации двигателя
brake_strength = 100          # Сила обратной связи от торможения
```

### Другие настройки

```ini
impact_hold = 85              # Как долго удерживается удар (0=мгновенно, 99=очень долго)
test_on_start = true          # Тестовая вибрация при обнаружении контроллера
dead_zone = 3                 # Значения мотора ниже этого обнуляются (0-10)
log_telemetry = false         # Подробное логирование телеметрии (для отладки)
```

### Расширенные пороги

Раскомментируйте в `config.txt` для тонкой настройки чувствительности:

| Настройка | По умолчанию | Описание |
|-----------|-------------|----------|
| `impact_delta_threshold` | `0.7` | Чувствительность к скачкам G-силы. Ниже = чувствительнее к контактам |
| `impact_abs_threshold` | `5.0` | Абсолютная G-сила для ударов о стены |
| `surface_threshold` | `60` | Порог скорости подвески. Ниже = больше ощущение дороги |
| `engine_rpm_threshold` | `4000` | Обороты для начала вибрации двигателя |
| `slip_threshold` | `3.0` | Порог обнаружения заноса |

## Сборка из исходников

Требуются Xcode Command Line Tools.

```bash
# Установить Xcode CLT (если не установлен)
xcode-select --install

# Сборка (обязательно x86_64 для Rosetta 2)
make clean && make all
```

Результат:
- `grid_vibfix.dylib` — библиотека фикса вибрации (x86_64)
- `stop_rumble` — утилита для остановки вибрации контроллера

## Как это работает

1. **Инъекция DYLD**: Dylib загружается в процесс игры через `DYLD_INSERT_LIBRARIES` (работает, потому что бинарник игры — неподписанный x86_64 под Rosetta 2)

2. **Обнаружение контроллера**: IOKit `IOHIDManager` находит Xbox-контроллеры по Vendor ID (`045E`) и Product ID

3. **Захват телеметрии**: Слушает UDP порт `20777` для телеметрии движка EGO (формат Codemasters — 66 float-ов, 30 Гц)

4. **Генерация эффектов**: Парсит данные телеметрии (G-силы, скорость подвески, скорости колёс, обороты, газ/тормоз) и генерирует 6 эффектов вибрации

5. **HID rumble**: Отправляет Xbox Bluetooth HID репорты (Report ID `0x03`, 9 байт) со значениями моторов 0-100

6. **Очистка**: Watchdog-поток обнуляет моторы когда телеметрия прекращается; утилита `stop_rumble` запускается после выхода из игры

## Решение проблем

| Проблема | Решение |
|----------|---------|
| Нет вибрации вообще | Проверьте, что контроллер подключён по Bluetooth (не USB). Проверьте `grid_vibfix.log` на ошибки |
| Нет тестовой вибрации при старте | Установите `test_on_start = true` в `config.txt`. Проверьте лог на "Xbox controller found" |
| Вибрация слишком сильная/слабая | Настройте `overall_strength` или силу отдельных эффектов в `config.txt` |
| Вибрация на прямых | Уменьшите `engine_strength` или увеличьте `engine_rpm_threshold` |
| Столкновения не ощущаются | Увеличьте `impact_strength` (напр. `150`) или уменьшите `impact_delta_threshold` (напр. `0.5`) |
| Вибрация остаётся в меню | Должна прекратиться в течение ~1 секунды. Если нет, `stop_rumble` запускается при выходе из игры |
| "bind() to port 20777 failed" | Другой процесс использует порт 20777. Закройте другие телеметрические приложения |
| Игра не запускается | Проверьте, что игра установлена в `/Applications/GRID Autosport/` |

## Файлы

| Файл | Описание |
|------|----------|
| `grid_vibfix.m` | Основной исходник — парсер телеметрии + генератор вибрации |
| `grid_vibfix.dylib` | Готовый dylib (x86_64) |
| `stop_rumble.m` | Утилита для остановки моторов контроллера |
| `stop_rumble` | Готовый stop_rumble (x86_64) |
| `config.txt` | Настройки вибрации |
| `run.sh` | Скрипт запуска (патчит конфиг + инъекция dylib) |
| `Makefile` | Правила сборки |
| `grid_vibfix.log` | Лог работы (создаётся при запуске игры) |

## Лицензия

MIT
