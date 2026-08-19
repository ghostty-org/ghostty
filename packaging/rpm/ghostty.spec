Name:           ghostty
Version:        %{version}
Release:        1%{?dist}
Summary:        A fast, feature-rich, and cross-platform terminal emulator
License:        MIT
URL:            https://ghostty.org
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  zig >= 0.16.0
BuildRequires:  pkg-config
BuildRequires:  gtk4-devel
BuildRequires:  libadwaita-devel
BuildRequires:  fontconfig-devel
BuildRequires:  freetype-devel
BuildRequires:  harfbuzz-devel
BuildRequires:  libpng-devel
BuildRequires:  zlib-devel
BuildRequires:  bzip2-devel
BuildRequires:  oniguruma-devel
BuildRequires:  git

Requires:       gtk4
Requires:       libadwaita
Requires:       fontconfig
Requires:       freetype
Requires:       harfbuzz
Requires:       libpng
Requires:       zlib

%description
Ghostty is a terminal emulator that differentiates itself by being designed
for high-throughput and low-latency while still having a rich feature set
including a GPU-accelerated renderer, a rich configuration system, and
platform-native UI elements.

%prep
%autosetup -n %{name}-%{version}

%build
zig build -Doptimize=ReleaseFast -Dpie=true

%install
# Binary
install -Dm755 zig-out/bin/ghostty %{buildroot}%{_bindir}/ghostty

# Desktop file
install -Dm644 dist/linux/app.desktop.in %{buildroot}%{_datadir}/applications/com.mitchellh.ghostty.desktop

# Metainfo
install -Dm644 dist/linux/com.mitchellh.ghostty.metainfo.xml.in %{buildroot}%{_datadir}/metainfo/com.mitchellh.ghostty.metainfo.xml

# Resources (terminfo, shell integration, themes)
mkdir -p %{buildroot}%{_datadir}/ghostty
cp -r zig-out/share/ghostty/* %{buildroot}%{_datadir}/ghostty/ || true

# Systemd user service
install -Dm644 dist/linux/systemd.service.in %{buildroot}%{_userunitdir}/ghostty.service || true

# D-Bus service
install -Dm644 dist/linux/dbus.service.in %{buildroot}%{_datadir}/dbus-1/services/com.mitchellh.ghostty.service || true

%files
%license LICENSE
%doc README.md
%{_bindir}/ghostty
%{_datadir}/applications/com.mitchellh.ghostty.desktop
%{_datadir}/metainfo/com.mitchellh.ghostty.metainfo.xml
%{_datadir}/ghostty/
%{_userunitdir}/ghostty.service
%{_datadir}/dbus-1/services/com.mitchellh.ghostty.service

%changelog
* Mon Jan 01 2024 Ghostty Maintainers <maintainers@ghostty.org> - %{version}-1
- Initial RPM package build via GitHub Actions
