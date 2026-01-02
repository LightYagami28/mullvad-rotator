# Mullvad VPN Server Rotator

🔄 Rotazione automatica dei server Mullvad VPN per una maggiore privacy

![License](https://img.shields.io/github/license/YOUR-USERNAME/mullvad-rotator)
![Version](https://img.shields.io/github/v/release/YOUR-USERNAME/mullvad-rotator)
![Stars](https://img.shields.io/github/stars/YOUR-USERNAME/mullvad-rotator?style=social)
![Issues](https://img.shields.io/github/issues/YOUR-USERNAME/mullvad-rotator)
![Last Commit](https://img.shields.io/github/last-commit/YOUR-USERNAME/mullvad-rotator)

![Platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-orange)
![VPN](https://img.shields.io/badge/VPN-Mullvad-green)
![Service](https://img.shields.io/badge/systemd-supported-blue)
![Protocol](https://img.shields.io/badge/protocol-WireGuard%20%7C%20OpenVPN-purple)

---

## ✨ Cos’è

**Mullvad VPN Server Rotator** cambia automaticamente il server Mullvad VPN a intervalli regolari, migliorando anonimato e riducendo il tracciamento online.

È pensato per funzionare **in background**, in modo affidabile, tramite **systemd**.

---

## 🚀 Funzionalità

- 🔄 Rotazione automatica dei server VPN
- 🌍 Selezione per paese o rotazione globale casuale
- 🛡️ Supporto WireGuard e OpenVPN
- 📝 Logging opzionale
- 🚀 Servizio systemd
- 🧙 Wizard di configurazione guidato
- 🔁 Retry automatici in caso di errore

---

## 📦 Installazione

👉 **Consulta il file dedicato:**  
📄 **[INSTALLATION.md](INSTALLATION.md)**

---

## ▶️ Utilizzo

```bash
sudo mullvad-rotator --setup     # Wizard di configurazione
sudo mullvad-rotator --status    # Stato VPN
sudo mullvad-rotator --config    # Configurazione attiva
sudo mullvad-rotator --stop      # Ferma la rotazione
mullvad-rotator --help           # Aiuto
