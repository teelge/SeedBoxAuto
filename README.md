<h1 align="center">
 
  SeedBoxAuto
  <br>
</h1>

<h4 align="center">A high-speed, interactive Bash script to deploy a complete Docker-based Media Seedbox.</h4>

<p align="center">
  <a href="https://github.com/teelge/SeedBoxAuto/stargazers">
    <img src="https://img.shields.io/github/stars/teelge/SeedBoxAuto.svg?style=flat" alt="Stars">
  </a>
  <a href="https://github.com/teelge/SeedBoxAuto/issues">
    <img src="https://img.shields.io/github/issues/teelge/SeedBoxAuto.svg" alt="Issues">
  </a>
  <a href="https://img.shields.io/badge/Architecture-x86__64%20%7C%20ARM64-orange.svg">
      <img src="https://img.shields.io/badge/Architecture-x86__64%20%7C%20ARM64-orange.svg">
  </a>
  <a href="https://img.shields.io/badge/Docker-Ready-blue.svg?logo=docker&logoColor=white">
      <img src="https://img.shields.io/badge/Docker-Ready-blue.svg">
  </a>
</p>

<p align="center">
  <a href="#key-features">Key Features</a> •
  <a href="#how-to-use">How To Use</a> •
  <a href="#directory-structure">Directory Structure</a> •
  <a href="#uninstall">Uninstall</a> •
  <a href="#license">License</a>
</p>

---

## Key Features

* **Universal Compatibility** - Automatically detects your OS (**Debian, Ubuntu, Arch**) and CPU (**Intel/AMD or Raspberry Pi**).
* **Interactive Setup** - Pick only the apps you need with a simple **Y/n** toggle.
* **Smart Defaults** - Built for speed; hit `Enter` to accept the best-practice defaults (**Yes**).
* **Idempotent & Safe** - Run it once, run it twice; it only changes what is necessary.
* **Permission Hardened** - Automatically uses **PUID/PGID** mapping to prevent root-owned file locks.
* **Audio-First** - Custom support for **Listenarr** with dedicated `audio` folder mapping.
* **Auto-Log Scraper** - Instantly displays your unique qBittorrent password upon deployment.

## How To Use
```bash
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/teelge/SeedBoxAuto/main/setup.sh | tr -d '\r')""
```
To Uninstall evrything and clean up:

```bash
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/teelge/SeedBoxAuto/main/uninstall.sh | tr -d '\r')"
```



