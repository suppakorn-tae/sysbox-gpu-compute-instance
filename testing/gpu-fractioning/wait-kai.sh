# wait for pods (args) to finish, print RESULT lines + scheduler annotations
for p in "$@"; do
  for i in $(seq 1 60); do ph=$(kubectl -n runai-llm-team get pod $p -o jsonpath='{.status.phase}' 2>/dev/null); [[ $ph == Succeeded || $ph == Failed ]] && break; sleep 5; done
  ann=$(kubectl -n runai-llm-team get pod $p -o jsonpath='{.metadata.annotations.nvidia\.com/container\.main\.gpu-memory\.request}')
  echo "== $p phase=$ph memreq=$ann $(kubectl -n runai-llm-team logs $p 2>&1 | grep -E 'RESULT|Error|error:' | tail -2)"
  [[ $ph == Pending || -z $ph ]] && kubectl -n runai-llm-team describe pod $p | sed -n '/Events/,$p' | tail -4
done
