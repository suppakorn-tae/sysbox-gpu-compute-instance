for p in "$@"; do
  for i in $(seq 1 72); do ph=$(kubectl -n runai-llm-team get pod $p -o jsonpath='{.status.phase}' 2>/dev/null); [[ $ph == Succeeded || $ph == Failed ]] && break; sleep 5; done
  echo "== $p phase=$ph $(kubectl -n runai-llm-team logs $p 2>&1 | grep -E 'RESULT|Error|Killed' | tail -1 | sed -E 's/"lim_env"[^}]*\}, //; s/"mps_mount": [a-z]+, //')"
done
