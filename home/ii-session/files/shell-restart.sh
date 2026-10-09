export PATH=@path@:$PATH
cfg="${qsConfig:-@qsConfig@}"
killall ydotool 2>/dev/null || true

# `qs kill` terminates ONE instance per call — it prints "Killed <id>" and
# returns, leaving any others running. Looping matters because the whole
# reason this script exists is that duplicates accumulate.
for _ in 1 2 3 4 5; do
  pgrep -f 'bin/quickshell -c' >/dev/null 2>&1 || break
  qs -c "$cfg" kill >/dev/null 2>&1 || break
done

# Backstop for an instance too wedged to answer its IPC socket. The pattern
# cannot match this script: its own cmdline is the store path below.
pkill -f 'bin/quickshell -c' 2>/dev/null || true

# Wait for them to actually exit. Starting the replacement while the old
# one still holds its layer surfaces is how you get two bars for a moment,
# and if the old one then fails to exit, permanently.
for _ in $(seq 1 50); do
  pgrep -f 'bin/quickshell -c' >/dev/null 2>&1 || break
  sleep 0.1
done

exec qs -c "$cfg" -d
