# 🍺 Homebrew Setup for Ghostty

Much simpler than scripts! With Homebrew, users can install and update Ghostty with standard brew commands.

## 🚀 Quick Setup (One-Time)

### 1. **Create the Homebrew Tap Repository**

```bash
# Navigate to homebrew-ghostty directory
cd homebrew-ghostty

# Initialize git repository  
git init
git add .
git commit -m "Initial Homebrew tap for Ghostty"

# Create repository on GitHub (replace with your username)
gh repo create fammasmaz/homebrew-ghostty --public --source=. --remote=origin --push
```

### 2. **Commit the Updated Build Workflow**

```bash
# Go back to main Ghostty repository
cd ..

# Commit the workflow changes
git add .github/workflows/build-macos-arm64.yml
git commit -m "Add latest release creation for Homebrew tap"
git push
```

### 3. **Test the Setup**

```bash
# Trigger a build to create the first "latest" release
gh workflow run build-macos-arm64.yml

# Wait for build to complete, then test the tap
brew tap fammasmaz/ghostty
brew install ghostty
```

## 🎯 **User Experience (Super Simple)**

### **Installation:**
```bash
brew tap fammasmaz/ghostty
brew install ghostty
```

### **Updates:**
```bash
# Update just Ghostty
brew upgrade ghostty

# Update everything (including Ghostty)
brew upgrade
```

### **Automatic Updates:**
```bash
# Add to crontab for daily auto-updates
echo "0 9 * * * /opt/homebrew/bin/brew upgrade" | crontab -
```

## 📋 **How It Works**

1. **Weekly Sync**: Your fork syncs with upstream weekly (via `.github/workflows/sync-upstream.yml`)
2. **Auto-Build**: When changes are detected, build workflow runs automatically
3. **Release Creation**: Build creates/updates a "latest" GitHub release
4. **Homebrew Detection**: `brew upgrade` detects new releases automatically
5. **Seamless Update**: Users get the latest version with `brew upgrade`

## ✨ **Benefits of Homebrew Approach**

✅ **Familiar**: Users already know `brew install` and `brew upgrade`  
✅ **Automatic**: Works with existing `brew upgrade` workflows  
✅ **Clean**: Proper uninstall with `brew uninstall --zap ghostty`  
✅ **Fast**: Homebrew handles caching and optimization  
✅ **Standard**: Follows macOS app distribution best practices  
✅ **Simple**: No custom scripts or authentication needed  

## 🔧 **Customization**

### **Update Cask Formula**
Edit `homebrew-ghostty/Casks/ghostty.rb`:
- Change GitHub repository URL
- Modify app metadata
- Adjust system requirements

### **Update Release Names**
Edit the workflow in `.github/workflows/build-macos-arm64.yml`:
- Change `tag_name` from "latest" 
- Customize release body content
- Modify artifact names

## 🐛 **Troubleshooting**

### **Release Issues:**
```bash
# Check if releases are being created
gh release list --repo fammasmaz/ghostty

# Manual release creation
gh release create latest dist/Ghostty-mac-arm64.zip --title "Latest Build" --repo fammasmaz/ghostty
```

### **Tap Issues:**
```bash
# Refresh tap information
brew untap fammasmaz/ghostty
brew tap fammasmaz/ghostty

# Force reinstall
brew reinstall ghostty
```

### **Build Issues:**
```bash
# Check workflow status
gh run list --repo fammasmaz/ghostty --workflow build-macos-arm64.yml

# Trigger manual build
gh workflow run build-macos-arm64.yml --repo fammasmaz/ghostty
```

## 🎉 **Final Result**

Your users can now:

1. **Install once**: `brew tap fammasmaz/ghostty && brew install ghostty`
2. **Update easily**: `brew upgrade` (works with their existing update routine)
3. **Stay current**: Automatic weekly sync ensures latest upstream changes
4. **Clean uninstall**: `brew uninstall --zap ghostty` removes everything

**Much simpler than custom scripts!** 🚀
