#!/bin/sh

cd $HOME

# .local/bin available to the compositor
if ! [ -e .config/environment.d/999-bin-paths.conf ]; then
  mkdir -p .config/environment.d
  cat > .config/environment.d/50-local-bin.conf << EOF
PATH="$PATH:${HOME}/.local/bin"
EOF
fi

if [ -e /etc/udev/rules.d ]; then
  if ! [ -e /etc/udev/rules.d/99-tpkbd-enable-fnlock.rules ]
    sudo install -m 0644 linux/99-tpkbd-enable-fnlock.rules /etc/udev/rules.d/
  fi
fi

if which gsettings &> /dev/null; then
  gsettings set org.gnome.desktop.interface font-antialiasing rgba
  # keyboard settings
  gsettings set org.gnome.desktop.peripherals.keyboard delay 225
  gsettings set org.gnome.desktop.peripherals.keyboard numlock-state false
  gsettings set org.gnome.desktop.peripherals.keyboard remember-numlock-state false
  gsettings set org.gnome.desktop.peripherals.keyboard repeat true
  gsettings set org.gnome.desktop.peripherals.keyboard repeat-interval 32
  gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'de+nodeadkeys')]"
fi

[ -e .gitconfig ] || ln -s $V1ENV/git/gitconfig .gitconfig
[ -e .vimrc ] || ln -s $V1ENV/vim/vimrc .vimrc

if ! [ -e .config/sway ]; then
	mkdir -p .config/sway
	ln -s $V1ENV/sway/config .config/sway/
fi

if ! [ -e .zshrc ]; then
	echo "export V1ENV=~/src/v1ne/v1env" >> .zshrc
	echo "source \${V1ENV}-private/zsh/${HOSTNAME}" >> .zshrc
fi

if ! [ -e .vimrc ]; then
	ln -s $V1ENV/vim/vimrc .vimrc
fi

if ! [ -e .vim ]; then
  mkdir .vim
	ln -s $V1ENV/vim/autoload .vim/autoload
	ln -s $V1ENV/vim/colors .vim/colors
fi

if [ -n "$LOCAL_VSCODE_USERJSON" ]; then
  python3 $V1ENV/vscode/update.py
else
  echo "Skipping VS Code settings merge: LOCAL_VSCODE_USERJSON not set"
fi

