# 🌀 Loopa Reality Installer (v1.0)

**Author:** Mr Void 💀  
**Type:** VLESS + TCP + REALITY 🔒  
**Version:** v1.0 (based on Loopa Core 3.2)

---

## ⚙️ Quick Install
Run this on your server (Ubuntu/Debian only):

```bash
sudo apt update -y && sudo apt install -y curl
curl -o loopa-reality.sh https://raw.githubusercontent.com/MrVoidLink/loopa-reality-installer/main/loopa-reality.sh
chmod +x loopa-reality.sh
sudo ./loopa-reality.sh
```

---

## 📄 What It Does
- Installs **Xray-core** if missing  
- Sanitizes your domain & SNI automatically  
- Generates secure **UUID**, **Private/Public keys**, **Short ID**  
- Builds full clean `config.json` (includes inbound + outbound)  
- Restarts Xray automatically  
- Generates **Reality link + QR**  
- Saves everything to `~/loopa-reality-PORT.txt`

---

## 🧩 Example
```
🌀 Welcome to Loopa Reality inbound creator (v1.0)
🔢 Enter port number (e.g. 443): 443
🌍 Enter your domain (e.g. vpn.loopa-vpn.com): vpn.loopa-vpn.com
🕵️ Enter camouflage SNI (e.g. www.google.com): www.google.com
🏷 Enter tag name (default: reality-443): test01
```

✅ Builds config  
✅ Prints QR  
✅ Saves your info to `~/loopa-reality-443.txt`

---

## 📦 Clean Uninstall
```bash
sudo systemctl stop xray
sudo systemctl disable xray
sudo rm -rf /usr/local/bin/xray /usr/local/etc/xray /etc/systemd/system/xray.service
sudo rm -f ~/loopa-reality.sh
sudo apt autoremove -y
```

---

## 🌐 Credits
> 🧠 Loopa Reality by **Mr Void 💀**  
> Version: v1.0 (Secure Build)  
> Repo: [MrVoidLink/loopa-reality-installer](https://github.com/MrVoidLink/loopa-reality-installer)
