import os, sys, time, json, torch
G=1024**3; out={}
out["mps_mount"]=any(" /run/nvidia-mps " in l for l in open("/proc/mounts"))
out["mps_env"]=os.environ.get("CUDA_MPS_PIPE_DIRECTORY")
out["lim_env"]={k:v for k,v in os.environ.items() if k.startswith(("NVIDIA_GPU","CUDA_MPS"))}
p=torch.cuda.get_device_properties(0); free,total=torch.cuda.mem_get_info()
out["SMs"]=p.multi_processor_count; out["total_GiB"]=round(total/G,3)
if os.environ.get("ALLOC","1")=="1":
    ch=[]
    try:
        while True: ch.append(torch.empty(64*1024**2,dtype=torch.uint8,device="cuda"))
    except Exception as e: out["alloc_max_GiB"]=round(len(ch)/16,3)
    del ch; torch.cuda.empty_cache()
n=8192; a=torch.randn(n,n,device="cuda"); b=torch.randn(n,n,device="cuda"); a@b; torch.cuda.synchronize()
# wait for common start time so concurrent pods overlap
st=float(os.environ.get("START_AT","0"))
while time.time()<st: time.sleep(0.05)
t=time.time(); it=0
while time.time()-t<float(os.environ.get("DWELL","20")): a@b; torch.cuda.synchronize(); it+=1
out["TFLOPS"]=round(2*n**3*it/(time.time()-t)/1e12,1)
print("RESULT", json.dumps(out), flush=True)
time.sleep(float(os.environ.get("HOLD","0")))
