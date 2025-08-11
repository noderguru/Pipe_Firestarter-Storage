# Pipe_Firestarter-Storage & firestarter🔥 role
Установим базовые системные пакеты для сборки, Rust (если его нет или он старый), исходники и бинарник Pipe CLI из GitHub-репозитория PipeNetwork/pipe

```bash
bash <(curl -sSL https://raw.githubusercontent.com/pipenetwork/pipe/main/setup.sh)
```
После окончания работы скрипта перезапустите терминал, и проверьте прописался ли pipe в PATH
```bash
pipe --version
````
если в ответе ```pipe 0.1.0``` или что-то подобное, то всё ок можно идти дальше)))

### Для получения роли firestarter🔥 нам надо немного повзаимодействовать с протоколом. Для этого запустим скрипт который выполнит все необходимые действия, а именно:

- Создаёт нового пользователя (или переиспользует существующего ~/.pipe-cli.json), показывает Solana Pubkey и просит получить DevNet SOL.

- Ждёт поступления SOL, затем делает своп SOL → PIPE (случайно 0.70–0.90 SOL с ретраями).

- Генерирует локальный файл случайного размера 50–150 Мб, загружает его (если my-file занят — создаёт my-file-<rnd>), ждёт доступность через pipe file-info, скачивает (есть фолбэк --legacy).

- Создаёт публичную ссылку на загруженный файл.

- Шифрует и загружает тот же файл с автогенерируемым паролем (≤8 символов); пароль показывается в логах и сохраняется в /root/pipe/secure-<name>.pass (+ запись в /root/pipe/passwords.log). Выполняет скачивание и расшифровку (std → --legacy фолбэк), затем сверяет SHA256.

- Генерирует 3 файла по 20–100 Мб и загружает каталог целиком (--skip-uploaded).

- Показывает отчёт токенов: pipe token-usage --period 30d --detailed.

после запуска скрипта создаётся новый пользователь, вас попросит придумать пароль - просто нажмите Enter ❗️❗️❗️

```bash
curl -O https://raw.githubusercontent.com/noderguru/Pipe_Firestarter-Storage/main/pipe_firestarter_workflow.sh && chmod +x pipe_firestarter_workflow.sh && ./pipe_firestarter_workflow.sh
```
когда скрипт закончит работу в логах будет написано что делать дальше
<img width="1173" height="354" alt="image" src="https://github.com/user-attachments/assets/5728d274-4609-4de8-92ce-3f2a89601a1c" />

# Админ в ДС написал кто в будущем хочет получить роль OG -- firestarter🔥 обязательна!!!

<img width="1403" height="190" alt="image" src="https://github.com/user-attachments/assets/6774a1ba-4e9f-45a0-a76c-177b21fdd0d4" />
