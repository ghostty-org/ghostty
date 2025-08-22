# 🚀 Ghostty Auto-Update Guide

Simple, automated updates using Homebrew.

## ⚡ Quick Start

### Install:
```bash
brew tap fammasmaz/ghostty
brew install ghostty
```

### Update:
```bash
brew upgrade ghostty
```

That's it! 🎉

## 🔄 How It Works

1. **Weekly Sync**: Fork automatically syncs with upstream Ghostty
2. **Auto-Build**: New builds trigger when changes detected
3. **Homebrew Ready**: Releases are created for Homebrew consumption
4. **Easy Updates**: Standard `brew upgrade` keeps you current

## 📋 Files Overview

- **`.github/workflows/sync-upstream.yml`** - Daily upstream sync
- **`.github/workflows/build-macos-arm64.yml`** - Build & release workflow  
- **`homebrew-ghostty/`** - Homebrew tap files
- **`HOMEBREW-SETUP.md`** - Detailed setup instructions

## 🛠️ First-Time Setup

See `HOMEBREW-SETUP.md` for complete setup instructions.

## ✨ Benefits

✅ **Familiar** - Standard Homebrew commands  
✅ **Automatic** - Works with `brew upgrade`  
✅ **Clean** - Proper macOS app management  
✅ **Simple** - No complex scripts or authentication  

Stay up-to-date with the latest Ghostty effortlessly! 🚀
