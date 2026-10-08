// Shared CUDA streams, events, and host status storage.
#pragma once

#include <cuda_runtime.h>

#include "sfc_keys.cuh"

namespace adaptive_octree::detail
{

    struct RebalanceState;

    struct CudaContext
    {
        cudaStream_t computeA{};
        cudaStream_t computeB{};
        cudaStream_t computeC{};
        cudaStream_t dToHStream{};

        cudaEvent_t readyA{};
        cudaEvent_t readyB{};
        cudaEvent_t readyC{};
        cudaEvent_t readyD{};
        cudaEvent_t stateReady{};

        int *changed_h = nullptr;

        RebalanceState *state_h{};
        TreeNodeIndex *newNumNodes_h = nullptr;

        CudaContext()
        {
            checkGpuErrors(cudaStreamCreateWithFlags(&computeA, cudaStreamNonBlocking));
            checkGpuErrors(cudaStreamCreateWithFlags(&computeB, cudaStreamNonBlocking));
            checkGpuErrors(cudaStreamCreateWithFlags(&computeC, cudaStreamNonBlocking));
            checkGpuErrors(cudaStreamCreateWithFlags(&dToHStream, cudaStreamNonBlocking));

            checkGpuErrors(cudaEventCreateWithFlags(&readyA, cudaEventDisableTiming));
            checkGpuErrors(cudaEventCreateWithFlags(&readyB, cudaEventDisableTiming));
            checkGpuErrors(cudaEventCreateWithFlags(&readyC, cudaEventDisableTiming));
            checkGpuErrors(cudaEventCreateWithFlags(&readyD, cudaEventDisableTiming));
            checkGpuErrors(cudaEventCreateWithFlags(&stateReady, cudaEventDisableTiming));

            checkGpuErrors(cudaMallocHost(reinterpret_cast<void **>(&changed_h), sizeof(int)));

            checkGpuErrors(cudaMallocHost(reinterpret_cast<void **>(&newNumNodes_h), sizeof(TreeNodeIndex)));
        }

        ~CudaContext()
        {
            if (changed_h)
                cudaFreeHost(changed_h);

            if (newNumNodes_h)
                cudaFreeHost(newNumNodes_h);

            cudaEventDestroy(readyA);
            cudaEventDestroy(readyB);
            cudaEventDestroy(readyC);
            cudaEventDestroy(readyD);

            cudaStreamDestroy(computeA);
            cudaStreamDestroy(computeB);
            cudaStreamDestroy(computeC);

            if (state_h)
                cudaFreeHost(state_h);

            if (stateReady)
                cudaEventDestroy(stateReady);

            if (dToHStream)
                cudaStreamDestroy(dToHStream);
        }

        CudaContext(const CudaContext &) = delete;
        CudaContext &operator=(const CudaContext &) = delete;
    };

} // namespace adaptive_octree::detail