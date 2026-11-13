import gc
import time
import torch

GIB = 1024**3
DEVICE = "cuda:0"

# Controlled test: cap matrix memory at approximately 9 GiB.
SIZES = [8192, 12288, 16384, 18432, 20480, 22528, 24576, 26624, 28672]
DWELL_SECONDS = 30
REPEATS = 3

print("PyTorch:", torch.__version__)
print("CUDA runtime:", torch.version.cuda)
print("GPU:", torch.cuda.get_device_name(0))
print("Reported total:",
      torch.cuda.get_device_properties(0).total_memory / GIB, "GiB")
print(f"Config: dwell={DWELL_SECONDS}s, repeats={REPEATS}")
print("N,estimated_GiB,elapsed_s,iterations,peak_GiB,result", flush=True)

for n in SIZES:
    a = b = c = None
    try:
        gc.collect()
        torch.cuda.empty_cache()
        torch.cuda.reset_peak_memory_stats()

        a = torch.randn((n, n), device=DEVICE, dtype=torch.float32)
        b = torch.randn((n, n), device=DEVICE, dtype=torch.float32)
        torch.cuda.synchronize()

        start = time.monotonic()
        deadline = start + DWELL_SECONDS
        iterations = 0

        while time.monotonic() < deadline:
            for _ in range(REPEATS):
                c = torch.mm(a, b)
                torch.cuda.synchronize()
                iterations += 1
                if time.monotonic() >= deadline:
                    break

        elapsed = time.monotonic() - start
        peak = torch.cuda.max_memory_allocated() / GIB
        estimated = 3 * n * n * 4 / GIB

        print(f"{n},{estimated:.2f},{elapsed:.2f},{iterations},"
              f"{peak:.2f},PASS", flush=True)

    except Exception as e:
        try:
            torch.cuda.synchronize()
        except Exception:
            pass
        peak = torch.cuda.max_memory_allocated() / GIB
        print(f"{n},{3*n*n*4/GIB:.2f},-, -, {peak:.2f},"
              f"FAIL:{type(e).__name__}:{e}", flush=True)
        break

    finally:
        del a, b, c
        gc.collect()
        try:
            torch.cuda.synchronize()
            torch.cuda.empty_cache()
        except Exception:
            pass

print("Test complete.")