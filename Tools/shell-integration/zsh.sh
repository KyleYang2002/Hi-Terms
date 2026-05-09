# Hi-Terms zsh shell integration (OSC 7 + OSC 133)
#
# Sourced from ~/.zshrc by Tools/install-shell-integration.sh.
# Emits:
#   OSC 7   — current working directory (file://host/url-encoded-path)
#   OSC 133;A — prompt about to be drawn (precmd)
#   OSC 133;B — user input begins (embedded inside PS1)
#   OSC 133;C — command submitted, output begins (preexec)
#   OSC 133;D;<exit> — command finished (precmd, before A)
#
# Idempotent: bails if HITERMS_SHELL_INTEGRATION is already set.

[[ -n "${HITERMS_SHELL_INTEGRATION:-}" ]] && return
export HITERMS_SHELL_INTEGRATION=1

# Percent-encode $PWD bytewise so any UTF-8 path round-trips through OSC 7.
__hiterms_osc7() {
    local enc
    enc=$(printf '%s' "$PWD" | od -An -vtx1 | tr -d ' \n' | sed 's/\(..\)/%\1/g')
    printf '\e]7;file://%s%s\e\\' "${HOST}" "${enc}"
}
__hiterms_osc133_A() { printf '\e]133;A\e\\'; }
__hiterms_osc133_B() { printf '\e]133;B\e\\'; }
__hiterms_osc133_C() { printf '\e]133;C\e\\'; }
__hiterms_osc133_D() { printf '\e]133;D;%s\e\\' "$1"; }

__hiterms_precmd() {
    local ec=$?
    __hiterms_osc133_D "$ec"
    __hiterms_osc7
    __hiterms_osc133_A
}
__hiterms_preexec() { __hiterms_osc133_C; }

# Embed B inside PS1 so the marker lands right before the user's input zone.
# %{...%} tells zsh the bytes inside take zero columns.
PS1='%{$(__hiterms_osc133_B)%}'"$PS1"

autoload -Uz add-zsh-hook
add-zsh-hook precmd  __hiterms_precmd
add-zsh-hook preexec __hiterms_preexec
