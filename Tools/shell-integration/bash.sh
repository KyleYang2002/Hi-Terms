# Hi-Terms bash shell integration (OSC 7 + OSC 133)
#
# Sourced from ~/.bashrc / ~/.bash_profile by Tools/install-shell-integration.sh.
# Targets bash 3.2 (macOS default) and bash >= 4.
# Emits the same OSC 7 / OSC 133 set as zsh.sh.
#
# Idempotent: bails if HITERMS_SHELL_INTEGRATION is already set.

[ -n "${HITERMS_SHELL_INTEGRATION-}" ] && return
export HITERMS_SHELL_INTEGRATION=1

# Bytewise percent-encode $PWD; works on macOS bash 3.2 + BSD od.
__hiterms_osc7() {
    local enc
    enc=$(printf '%s' "$PWD" | od -An -vtx1 | tr -d ' \n' | sed 's/\(..\)/%\1/g')
    printf '\e]7;file://%s%s\e\\' "${HOSTNAME-localhost}" "${enc}"
}
__hiterms_osc133_A() { printf '\e]133;A\e\\'; }
__hiterms_osc133_B() { printf '\e]133;B\e\\'; }
__hiterms_osc133_C() { printf '\e]133;C\e\\'; }
__hiterms_osc133_D() { printf '\e]133;D;%s\e\\' "$1"; }

# DEBUG trap fires before EVERY command, including ones bash itself runs as
# part of PROMPT_COMMAND. The guards below filter to "the user's command line
# only".
__hiterms_preexec_trap() {
    # Programmable completion runs commands with COMP_LINE set; ignore them.
    [ -n "${COMP_LINE-}" ] && return
    # Bash invokes PROMPT_COMMAND inline; suppress its own DEBUG firings.
    [ "${BASH_COMMAND}" = "${PROMPT_COMMAND}" ] && return
    # Re-entrancy guard: while __hiterms_prompt is running, every helper it
    # calls would otherwise emit a spurious C marker.
    [ -n "${__hiterms_in_prompt-}" ] && return
    __hiterms_osc133_C
}
trap '__hiterms_preexec_trap' DEBUG

__hiterms_prompt() {
    local ec=$?
    __hiterms_in_prompt=1
    __hiterms_osc133_D "$ec"
    __hiterms_osc7
    __hiterms_osc133_A
    unset __hiterms_in_prompt
    return $ec
}

# Chain (don't replace) any existing PROMPT_COMMAND.
case "${PROMPT_COMMAND-}" in
    *__hiterms_prompt*) ;;  # already chained
    "")  PROMPT_COMMAND='__hiterms_prompt' ;;
    *)   PROMPT_COMMAND='__hiterms_prompt;'"${PROMPT_COMMAND}" ;;
esac

# Embed B inside PS1 wrapped with \[...\] so readline counts zero columns.
case "$PS1" in
    *__hiterms_osc133_B*) ;;  # already wrapped
    *) PS1='\[$(__hiterms_osc133_B)\]'"$PS1" ;;
esac
