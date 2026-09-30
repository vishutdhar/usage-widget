# Sourced by install.sh. Ends every process whose executable path is
# exactly $1: compared as a plain string, never as a pattern, so a path that
# differs only where a pattern would allow any character is left alone.
kill_exact_executable() {
    local target="$1" pid comm
    ps -axo pid=,comm= | while read -r pid comm; do
        if [ "$comm" = "$target" ]; then
            kill "$pid" 2>/dev/null || true
        fi
    done
}
