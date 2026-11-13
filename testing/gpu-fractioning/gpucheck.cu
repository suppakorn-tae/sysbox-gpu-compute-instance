// gpucheck: what a CUDA program sees and can do inside a GPU fraction.
//   nvcc -O2 -o gpucheck gpucheck.cu && ./gpucheck [seconds]
// Prints SM count, reported total/free memory, how much it can allocate, and
// FMA throughput over a short busy loop.
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <cuda_runtime.h>

__global__ void burn(float *x, int iters) {
  float a = x[threadIdx.x], b = 1.0001f;
  for (int i = 0; i < iters; i++) a = a * b + 0.5f;
  x[threadIdx.x] = a;
}

int main(int argc, char **argv) {
  double secs = argc > 1 ? atof(argv[1]) : 3.0;
  int dev = 0, sms = 0;
  if (cudaDeviceGetAttribute(&sms, cudaDevAttrMultiProcessorCount, dev) != cudaSuccess) {
    printf("CUDA unavailable: %s\n", cudaGetErrorString(cudaGetLastError()));
    return 1;
  }
  size_t freeB, totalB;
  cudaMemGetInfo(&freeB, &totalB);
  std::vector<void *> chunks;
  void *p;
  while (cudaMalloc(&p, 64 << 20) == cudaSuccess) chunks.push_back(p);
  cudaGetLastError();
  double allocGiB = chunks.size() * 64.0 / 1024;
  for (void *c : chunks) cudaFree(c);

  float *x;
  cudaMalloc(&x, 1024 * sizeof(float));
  cudaEvent_t s, e;
  cudaEventCreate(&s);
  cudaEventCreate(&e);
  const int iters = 1 << 16, blocks = sms * 32;
  burn<<<blocks, 1024>>>(x, 16);
  cudaDeviceSynchronize();
  long launches = 0;
  float ms = 0;
  cudaEventRecord(s);
  while (ms < secs * 1000) {
    burn<<<blocks, 1024>>>(x, iters);
    launches++;
    cudaEventRecord(e);
    cudaEventSynchronize(e);
    cudaEventElapsedTime(&ms, s, e);
  }
  double tflops = 2.0 * iters * 1024.0 * blocks * launches / (ms / 1000) / 1e12;
  printf("GPUCHECK SMs=%d total_GiB=%.2f free_GiB=%.2f alloc_GiB=%.2f fma_TFLOPS=%.1f\n",
         sms, totalB / 1073741824.0, freeB / 1073741824.0, allocGiB, tflops);
  return 0;
}
