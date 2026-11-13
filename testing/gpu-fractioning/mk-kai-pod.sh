# usage: mk-kai-pod.sh NAME RUNTIMECLASS "ANNOTATIONS" ENV_YAML CMD_JSON | kubectl apply -f -
# NAME RC ANN ENVJSON CMD
NAME=$1; RC=$2; ANN=$3; ENVS=${4:-[]}; CMD=${5:-'["python","/probe/frac-probe.py"]'}
cat <<Y
apiVersion: v1
kind: Pod
metadata:
  name: $NAME
  namespace: runai-llm-team
  labels: {project: llm-team, app: frac-probe}
  annotations: {${ANN}}
spec:
  schedulerName: runai-scheduler
  restartPolicy: Never
  $( [ -n "$RC" ] && echo "runtimeClassName: $RC" )
  $( [[ "$RC" == *sysbox* ]] && echo "hostUsers: false" )
  containers:
  - name: main
    image: nvcr.io/nvidia/pytorch:26.09-py3
    imagePullPolicy: IfNotPresent
    command: $CMD
    env: $ENVS
    resources: {requests: {cpu: "1", memory: 4Gi}, limits: {memory: 14Gi}}
    volumeMounts: [{name: p, mountPath: /probe}]
  volumes: [{name: p, configMap: {name: frac-probe}}]
Y
