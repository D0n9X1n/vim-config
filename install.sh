#!/bin/bash

# refer  spf13-vim bootstrap.sh`
BASEDIR=$(dirname $0)
cd $BASEDIR
CURRENT_DIR=`pwd`

lnif() {
    if [ -e "$1" ]; then
        ln -sf "$1" "$2"
    fi
}


echo "Step1: backing up current vim config"
today=`date +%Y%m%d`
for i in $HOME/.vim $HOME/.vimrc $HOME/.gvimrc $HOME/.vimrc.bundles $HOME/.vimrc.private; do [ -e $i ] && [ ! -L $i ] && mv $i $i.$today; done
for i in $HOME/.vim $HOME/.vimrc $HOME/.gvimrc $HOME/.vimrc.bundles $HOME/.vimrc.private; do [ -L $i ] && unlink $i ; done


echo "Step2: setting up symlinks"
touch vimrc.private
lnif $CURRENT_DIR/vimrc $HOME/.vimrc
lnif $CURRENT_DIR/vimrc.bundles $HOME/.vimrc.bundles
lnif $CURRENT_DIR/vimrc.private $HOME/.vimrc.private
lnif "$CURRENT_DIR/" "$HOME/.vim"

touch "$HOME/.vimrc.private"


# Step3: install declared plugins, then remove checkouts no longer declared.
# Use a minimal init that loads the same declarations as vimrc (bundles and
# private overlay) and nothing else: the full vimrc's colorscheme call
# fails before the theme exists. `vim` here is the shell lookup, not an alias.
VIM_BIN=$(command -v vim || true)
if [ -n "$VIM_BIN" ] && "$VIM_BIN" --version 2>/dev/null | head -n 1 | grep -q '^VIM'; then
    echo "Step3: installing plugins"
    PRUNE_DIR=$(mktemp -d)
    trap 'rm -rf -- "$PRUNE_DIR"' EXIT
    cat > "$PRUNE_DIR/init.vim" <<'VIM'
set nocompatible
set runtimepath^=~/.vim
call plug#begin('~/.vim/bundle')
" Inside :try, any error in a declaration file aborts it; the plugin list is
" written only when both files loaded, so a broken overlay removes nothing.
let g:prune_declarations_ok = 0
try
    if filereadable(expand("~/.vimrc.bundles"))
        source ~/.vimrc.bundles
    endif
    if filereadable(expand("~/.vimrc.private"))
        source ~/.vimrc.private
    endif
    let g:prune_declarations_ok = 1
catch
endtry
call plug#end()
VIM
    "$VIM_BIN" -N -u "$PRUNE_DIR/init.vim" -i NONE -c 'PlugInstall --sync' -c 'qa!' </dev/null >/dev/null 2>&1 || true
    export VIM_PRUNE_DECLARED="$PRUNE_DIR/declared"
    "$VIM_BIN" -N -u "$PRUNE_DIR/init.vim" -i NONE -es \
        -c 'if g:prune_declarations_ok | call writefile(map(values(g:plugs), {_, p -> fnamemodify(substitute(p.dir, "/$", "", ""), ":t")}), $VIM_PRUNE_DECLARED) | endif' \
        -c 'qa!' </dev/null >/dev/null 2>&1 || true
    if [ -s "$VIM_PRUNE_DECLARED" ]; then
        "$BASH" "$CURRENT_DIR/tools/prune-plugins.sh" "$HOME/.vim/bundle" "$VIM_PRUNE_DECLARED" || true
    else
        echo "Note: could not read the plugin list; no plugins were removed."
    fi
    echo "Install Done!"
else
    echo "Install Done! open your vim and run :PlugInstall !"
fi
