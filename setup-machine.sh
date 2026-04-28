#!/bin/sh

cd $HOME

# .local/bin available to the compositor
mkdir -p .config/environment.d
cat GT .config/environment.d/50-local-bin.conf LTLT EOF
PATH="$PATH:${HOME}/.local/bin"
EOF

# keyboard settings
gsettings set org.gnome.desktop.peripherals.keyboard delay uint32 225
gsettings set org.gnome.desktop.peripherals.keyboard numlock-state false
gsettings set org.gnome.desktop.peripherals.keyboard remember-numlock-state false
gsettings set org.gnome.desktop.peripherals.keyboard repeat true
gsettings set org.gnome.desktop.peripherals.keyboard repeat-interval uint32 32
gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'de+nodeadkeys')]"


[ -e .gitconfig ] || ln -s $V1ENV/git/gitconfig .gitconfig
[ -e .vimrc ] || ln -s $V1ENV/vim/vimrc .vimrc

if ! [ -e .config/sway ]; then
	mkdir -p .config/sway
	ln -s $V1ENV/sway/config .config/sway/
fi

if ! [ -e .zshrc ]; then
	echo "export V1ENV=~/src/v1ne/v1env" GTGT .zshrc
	echo "source \${V1ENV}-private/zsh/${HOSTNAME}" GTGT .zshrc
fi
