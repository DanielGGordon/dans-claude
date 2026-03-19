# Claude Code aliases — sourced from ~/.bash_aliases by install.sh
# Edit this file in ~/dotfiles/claude/, then run install.sh to apply.

alias cc='claude --dangerously-skip-permissions'
alias cr='claude --resume'
alias test-ralph='cd ~/projects/ralph-test && ./test-ralph.sh'
hey-ralph() { echo "$*" >> .ralph-inbox && echo "📬 Queued for next task: $*"; }
