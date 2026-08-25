#!/bin/sh

cd $HOME
mkdir -p .config
mkdir -p .local/share

# alacritty
if ! [ -e .config/alacritty ]; then
  mkdir .config/alacritty
  ln -s $V1ENV/alacritty/alacritty.toml .config/alacritty/
  ln -s $V1ENV/alacritty/themes .config/alacritty/
  (cd .config/alacritty && ln -s themes/light.toml theme.toml)
fi

# darkman
if which darkman 2>&1 > /dev/null && ! [ -e .config/darkman ]; then
  mkdir -p .config/darkman
  ln -s $V1ENV/darkman/config.yaml .config/darkman/config.yaml
  ln -s $V1ENV/darkman/scripts .local/share/darkman
  systemctl --user enable --now darkman.service
fi

# environment
# Sort above 99-environment.conf: /etc/environment assigns PATH absolutely.
mkdir -p .config/environment.d
rm -f .config/environment.d/50-local-bin.conf
cat > .config/environment.d/995-local-bin.conf << EOF
PATH="\$PATH:\$HOME/.local/bin:\$HOME/.go/bin:\$HOME/.cargo/bin"
EOF
if ! [ -e .config/environment.d/51-v1env.conf ]; then
  cat > .config/environment.d/51-v1env.conf << EOF
V1ENV=$V1ENV
EOF
fi
if ! [ -e .config/environment.d/52-gopath.conf ]; then
  cat > .config/environment.d/52-gopath.conf << EOF
GOPATH="\${HOME}/.go"
EOF
export GOPATH="${HOME}/.go"
fi
# The user manager outlives a logout, so it would keep serving a stale PATH.
systemctl --user daemon-reload

# Git
[ -e .gitconfig ] || ln -s $V1ENV/git/gitconfig .gitconfig
if ! which gorun 2>&1 > /dev/null; then
  go install github.com/erning/gorun@latest
fi

# gsettings
if which gsettings 2>&1 > /dev/null; then
  gsettings set org.gnome.desktop.interface font-antialiasing rgba
  # keyboard settings
  gsettings set org.gnome.desktop.peripherals.keyboard delay 225
  gsettings set org.gnome.desktop.peripherals.keyboard numlock-state false
  gsettings set org.gnome.desktop.peripherals.keyboard remember-numlock-state false
  gsettings set org.gnome.desktop.peripherals.keyboard repeat true
  gsettings set org.gnome.desktop.peripherals.keyboard repeat-interval 32
  gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'de+nodeadkeys')]"
fi

# Mako
if ! [ -e .config/mako ]; then
  mkdir -p .config/mako
  ln -s $V1ENV/sway/mako/config .config/mako/config
fi

# neovim
if ! [ -e .config/nvim ]; then
  mkdir -p .config/nvim
  ln -s $V1ENV/vim/init.vim .config/nvim/init.vim
fi

# shikane
if ! which shikane 2>&1 > /dev/null; then
  if which cargo 2>&1 > /dev/null; then
    cargo install --quiet --locked shikane
  else
    echo "Skipping shikane install: cargo not found"
  fi
fi
if ! [ -e .config/shikane ]; then
  mkdir -p .config/shikane
  SHIKANE_CFG=$V1ENV-private/shikane/$(hostname).toml
  [ -e $SHIKANE_CFG ] || SHIKANE_CFG=$V1ENV/sway/shikane/default.toml
  ln -s $SHIKANE_CFG .config/shikane/config.toml
fi

# Sway
if ! [ -e .config/sway ]; then
	mkdir -p .config/sway
	ln -s $V1ENV/sway/config .config/sway/
  # for brightnessctl:
  sudo usermod -aG video $USER
fi

# udev
if [ -e /etc/udev/rules.d ]; then
  if ! [ -e /etc/udev/rules.d/99-tpkbd-enable-fnlock.rules ]; then
    sudo install -m 0644 $V1ENV/linux/99-tpkbd-enable-fnlock.rules /etc/udev/rules.d/
  fi
fi

# vim
if ! [ -e .vimrc ]; then
	ln -s $V1ENV/vim/vimrc .vimrc
fi

if ! [ -e .vim ]; then
  mkdir .vim
	ln -s $V1ENV/vim/autoload .vim/autoload
	ln -s $V1ENV/vim/colors .vim/colors
fi

# VS Code
if [ -n "$LOCAL_VSCODE_USERJSON" ]; then
  python3 $V1ENV/vscode/update.py
else
  echo "Skipping VS Code settings merge: LOCAL_VSCODE_USERJSON not set"
fi

# waybar
if ! [ -e .config/waybar ]; then
  ln -s $V1ENV/sway/waybar .config/waybar
fi

# zsh
if ! [ -e .zshrc ]; then
	echo "export V1ENV=~/src/v1ne/v1env" >> .zshrc
	echo "source \${V1ENV}-private/zsh/${HOSTNAME}" >> .zshrc
fi

