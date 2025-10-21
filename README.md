# 🌀 Loopa Reality Installer (v1.0)

Smart and secure installer for **Xray (VLESS + TCP + REALITY)** — built by **Mr Void 💀**.

---

## 🚀 Quick Install
Run this one-line command as **root** on your Ubuntu server:
```bash
bash -c "$(curl -L https://raw.githubusercontent.com/MrVoidLink/loopa-reality-installer/main/loopa-reality.sh)"
```

It will automatically:
- 🧩 Install dependencies (`curl`, `jq`, `openssl`, `qrencode`)
- ⚙️ Install **Xray-core** if missing  
- 🔒 Create **VLESS + REALITY** inbound config  
- 🔐 Generate private/public keys, UUID, shortId  
- 🧠 Sanitize your domain & SNI safely  
- 🪄 Restart Xray and show QR/link ready to scan  

---

## ✨ Features
✅ Builds a clean `config.json` (always includes inbound + outbound)  
✅ Validates and sanitizes domain & SNI (prevents Persian or special chars)  
✅ Generates **X25519 keys + UUID + ShortID**  
✅ Creates and saves ready-to-scan **QR code**  
✅ Outputs clean `~/loopa-reality-PORT.txt` info file  
✅ Automatically restarts Xray safely  

---

## 📄 Example Output
After creating a new Reality config:
```
✅ Reality inbound successfully added!
-----------------------------------------------
Tag        : reality-443
Domain     : vpn.loopa-vpn.com
SNI        : www.google.com
UUID       : 123e4567-e89b-12d3-a456-426614174000
ShortId    : 44ddc2e36398525c
Port       : 443
-----------------------------------------------
Reality Link:
vless://123e4567-e89b-12d3-a456-426614174000@vpn.loopa-vpn.com:443?security=reality&sni=www.google.com&pbk=AABBCCDD&sid=44ddc2e36398525c&fp=chrome&type=tcp#reality-443
-----------------------------------------------
📱 QR Code (scan with v2rayNG)
```

---

## 🧠 Requirements
- Ubuntu **20.04 / 22.04 / 24.04**
- Root access  
- Internet connection  

---

## 💡 Notes
- Uses official [XTLS/Xray-install](https://github.com/XTLS/Xray-install) for core setup  
- Config saved at `/usr/local/etc/xray/config.json`  
- Output summary file stored at `~/loopa-reality-PORT.txt`  
- Safe to rerun multiple times — script always rebuilds clean configs  

---

## 🧰 File Structure
```
loopa-reality.sh    → Main installer script
README.md           → Documentation and usage guide
```

---

## 💬 Author
Developed by **Mr Void 💀**  
🔗 GitHub: [@MrVoidLink](https://github.com/MrVoidLink)

---

## 🪪 License
**MIT License** © 2025 Mr Void  
Free to use, modify, and distribute — just keep credits intact.
