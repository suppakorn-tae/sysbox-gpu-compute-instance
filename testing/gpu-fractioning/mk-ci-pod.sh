# usage: mk-ci-pod.sh NAME FRACTION SM_PERCENT MPS_NS ENV_YAML [SHELL_CMD] | kubectl apply -f -
# NAME FRACTION SMPCT NSNAME ENVYAML [SHELLCMD]
NAME=$1; FR=$2; PCT=$3; NS=$4; ENVS=${5:-[]}; SH=${6:-'CUDA_MPS_PIPE_DIRECTORY=/run/ci-mps exec python /probe/frac-probe.py'}
cat <<Y
apiVersion: v1
kind: Pod
metadata:
  name: $NAME
  namespace: runai-llm-team
  labels: {project: llm-team, app: ci-test}
  annotations: {gpu-fraction: "$FR", ci.gpu/sm-percent: "$PCT", ci.gpu/mps-ns: "$NS"}
spec:
  schedulerName: runai-scheduler
  runtimeClassName: nvidia-sysbox
  hostUsers: false
  restartPolicy: Never
  containers:
  - name: main
    image: nvcr.io/nvidia/pytorch:26.09-py3
    imagePullPolicy: IfNotPresent
    command: ["sh","-c",'$SH']
    env: $ENVS
    resources: {requests: {cpu: "1", memory: 4Gi}, limits: {memory: 14Gi}}
    volumeMounts: [{name: p, mountPath: /probe}, {name: ci-mps, mountPath: /run/ci-mps}]
  volumes:
  - {name: p, configMap: {name: frac-probe}}
  - {name: ci-mps, hostPath: {path: /run/nvidia-mps/shared/$NS, type: Directory}}
Y
