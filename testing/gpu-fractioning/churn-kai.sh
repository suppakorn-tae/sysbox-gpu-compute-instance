# usage: RC=<runtimeClass or empty> churn-kai.sh PREFIX N CMDJSON   (alternates gpu-fraction 0.1 / 0.75)
# churn-kai.sh PREFIX N CMDJSON
S=$(cd "$(dirname "$0")" && pwd); PFX=$1; N=$2; CMD=$3; bad=0
for i in $(seq 1 $N); do
  if (( i % 2 )); then fr=0.1; else fr=0.75; fi; n=$PFX$i
  bash $S/mk-kai-pod.sh $n "$RC" "gpu-fraction: \"$fr\"" '[{name: DWELL, value: "1"}]' "$CMD" | kubectl apply -f - >/dev/null
  for j in $(seq 1 60); do ph=$(kubectl -n runai-llm-team get pod $n -o jsonpath='{.status.phase}'); [[ $ph == Succeeded || $ph == Failed ]] && break; sleep 2; done
  got=$(kubectl -n runai-llm-team logs $n 2>&1 | grep -o '"total_GiB": [0-9.]*' | cut -d' ' -f2); exp=$(python3 -c "print(round($fr*40,1))")
  [[ "$got" != "$exp" ]] && { bad=$((bad+1)); flag="  <-- STALE"; } || flag=""
  echo "$n fr=$fr expect=$exp got=$got$flag"
  kubectl -n runai-llm-team delete pod $n --wait=true >/dev/null
done
echo "stale: $bad / $N"
