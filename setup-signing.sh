#!/bin/bash
# Одноразове налаштування сталого self-signed підпису для ShotShot.
# Робить дозвіл «Запис екрана» таким, що переживає перекомпіляції.
set -e
cd "$(dirname "$0")"

IDENT="ShotShot Dev"
KC="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning | grep -q "$IDENT"; then
  echo "✅ Ідентичність «$IDENT» вже існує — пропускаю створення."
else
  echo "→ Створюю самопідписаний сертифікат «$IDENT»…"
  WORK=$(mktemp -d)
  cat > "$WORK/cs.cnf" <<'EOF'
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = v3_cs
[ dn ]
CN = ShotShot Dev
[ v3_cs ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 3650 \
    -config "$WORK/cs.cnf" -extensions v3_cs >/dev/null 2>&1
  # OpenSSL 3 ↔ Apple: потрібні legacy-алгоритми + SHA1 MAC + непорожній пароль,
  # інакше `security import` падає з "MAC verification failed".
  openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/id.p12" -passout pass:temp123 -macalg sha1 \
    -certpbe pbeWithSHA1And3-KeyTripleDES-CBC \
    -keypbe pbeWithSHA1And3-KeyTripleDES-CBC >/dev/null 2>&1
  security import "$WORK/id.p12" -k "$KC" -P temp123 -T /usr/bin/codesign
  rm -rf "$WORK"
  echo "✅ Сертифікат створено й імпортовано у login keychain."
fi

echo
echo "→ Введи пароль від macOS (щоб codesign міг підписувати без щоразових GUI-запитів):"
read -s PW
security set-key-partition-list -S apple-tool:,apple: -s -k "$PW" "$KC" >/dev/null
echo "✅ codesign авторизовано користуватись ключем."

# Скидаємо застарілі (ad-hoc) дозволи Запису екрана для ShotShot
tccutil reset ScreenCapture com.ek.shotshot >/dev/null 2>&1 || true
echo "✅ Старий дозвіл «Запис екрана» для ShotShot скинуто."

echo
echo "Готово. Далі:  ./build.sh  і при першому ⌘⇧7 дай доступ ОДИН раз —"
echo "після сталого підпису він триматиметься й після перекомпіляцій."