env -i \
  HOME="$HOME" \
  PATH="/usr/local/cuda/bin:/usr/local/bin:/usr/bin:/bin" \
  "$HOME/hami-mem-test/.venv/bin/python" stress_test.py