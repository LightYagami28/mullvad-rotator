# Installation Guide – Mullvad VPN Server Rotator

Benvenuto nella guida di installazione per **Mullvad VPN Server Rotator**! Segui questi passaggi per configurare il software sul tuo sistema Debian o Ubuntu.

## 🖥️ Requisiti

- Debian **12 / 13** oppure Ubuntu **22.04+**
- Account Mullvad VPN attivo
- Accesso **sudo / root**
- Connessione Internet funzionante

---

## 1️⃣ Installare Mullvad VPN

Se Mullvad VPN non è già installato sul sistema:

```bash
curl -fsSL https://mullvad.net/media/mullvad-signing-key.asc \
  | sudo gpg --dearmor -o /usr/share/keyrings/mullvad.gpg

echo "deb [signed-by=/usr/share/keyrings/mullvad.gpg] https://repository.mullvad.net/deb/stable $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/mullvad.list

sudo apt update
sudo apt install mullvad-vpn
````

Verifica che il servizio Mullvad sia attivo:

```bash
sudo systemctl status mullvad-daemon
```

---

## 2️⃣ Login all’account Mullvad

Accedi utilizzando il tuo numero di account Mullvad:

```bash
mullvad account login NUMERO-ACCOUNT
```

Verifica lo stato della connessione:

```bash
mullvad status
```

---

## 3️⃣ Installare Mullvad VPN Server Rotator

Scarica lo script principale:

```bash
sudo curl -Lo /usr/local/bin/mullvad-rotator \
https://raw.githubusercontent.com/YOUR-USERNAME/mullvad-rotator/main/mullvad-rotator
```

Rendi il file eseguibile:

```bash
sudo chmod +x /usr/local/bin/mullvad-rotator
```

---

## 4️⃣ Avviare il wizard di configurazione

Esegui il wizard interattivo:

```bash
sudo mullvad-rotator --setup
```

Il wizard si occuperà automaticamente di:

- verifica dei requisiti
- scelta del paese (o rotazione globale)
- impostazione dell’intervallo di rotazione
- selezione del protocollo (WireGuard / OpenVPN)
- configurazione dei log
- installazione e avvio del servizio **systemd**

---

## 5️⃣ Verifica del servizio

Controlla che il servizio sia attivo:

```bash
sudo systemctl status mullvad-rotator
```

Per visualizzare i log in tempo reale:

```bash
sudo journalctl -u mullvad-rotator -f
```

---

## ⚙️ File di configurazione

Il file di configurazione viene creato automaticamente in:

```text
/etc/mullvad-rotator.conf
```

Può essere modificato manualmente se necessario:

```bash
sudo nano /etc/mullvad-rotator.conf
```

---

## 🧯 Problemi comuni

### Mullvad VPN non connesso

```bash
mullvad connect
```

---

### Il servizio risulta già in esecuzione

```bash
sudo systemctl stop mullvad-rotator
sudo rm -f /run/mullvad-rotator.lock
```

---

### Il servizio Mullvad non è attivo

```bash
sudo systemctl start mullvad-daemon
```

---

## 🗑️ Disinstallazione

Per rimuovere completamente Mullvad VPN Server Rotator:

```bash
sudo systemctl stop mullvad-rotator
sudo systemctl disable mullvad-rotator

sudo rm /usr/local/bin/mullvad-rotator
sudo rm /etc/systemd/system/mullvad-rotator.service
sudo rm /etc/mullvad-rotator.conf
sudo rm /var/log/mullvad-rotator.log

sudo systemctl daemon-reload
```

---

## ✅ Installazione completata

Mullvad VPN Server Rotator è ora installato e funzionante 🎉
Per l’utilizzo quotidiano, consulta **README.md**.
