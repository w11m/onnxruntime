/*
 * Copyright (c) 2022-2024, NVIDIA CORPORATION.  All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "core/providers/shared_library/provider_api.h"
#include "custom_reduce_impl.h"
#include <algorithm>
#include <cstdint>
#include <tuple>
#include <type_traits>

namespace ort_trtllm {

// Calculates ceil(a / b). User must be careful to ensure that there
// is no overflow or underflow in the calculation.
template <typename T> constexpr T divUp(T a, T b) { return (a + b - (T)1) / b; }

// Rounds a up to the next highest multiple of b. User must be careful
// to ensure that there is no overflow or underflow in the calculation
// of divUp.
template <typename T> constexpr T roundUp(T a, T b) { return divUp<T>(a, b) * b; }

////////////////////////////////////////////////////////////////////////////////////////////////////

static inline __device__ void st_flag_release(uint32_t const &flag, uint32_t *flag_addr) {
#if __CUDA_ARCH__ >= 700
    asm volatile("st.global.release.sys.b32 [%1], %0;" ::"r"(flag), "l"(flag_addr));
#else
    __threadfence_system();
    asm volatile("st.global.volatile.b32 [%1], %0;" ::"r"(flag), "l"(flag_addr));
#endif
}

////////////////////////////////////////////////////////////////////////////////////////////////////

static inline __device__ uint32_t ld_flag_acquire(uint32_t *flag_addr) {
    uint32_t flag;
#if __CUDA_ARCH__ >= 700
    asm volatile("ld.global.acquire.sys.b32 %0, [%1];" : "=r"(flag) : "l"(flag_addr));
#else
    asm volatile("ld.global.volatile.b32 %0, [%1];" : "=r"(flag) : "l"(flag_addr));
#endif
    return flag;
}

////////////////////////////////////////////////////////////////////////////////////////////////////

// Type Converter that packs data format to 128 bits data type
//
using PackedFloat = union {
    int4 packed;
    float unpacked[4];
};

using PackedHalf = union {
    int4 packed;
    half2 unpacked[4];
};

template <typename T> struct PackedOn16Bytes {};

template <> struct PackedOn16Bytes<float> {
    using Type = PackedFloat;
};

template <> struct PackedOn16Bytes<half> {
    using Type = PackedHalf;
};

// add two 128b data
template <typename T> inline __device__ int4 add128b(T &a, T &b) {
    T c;
    c.unpacked[0] = a.unpacked[0] + b.unpacked[0];
    c.unpacked[1] = a.unpacked[1] + b.unpacked[1];
    c.unpacked[2] = a.unpacked[2] + b.unpacked[2];
    c.unpacked[3] = a.unpacked[3] + b.unpacked[3];
    return c.packed;
}

__inline__ __device__ void multi_gpu_barrier(uint32_t **signals, uint32_t const flag, size_t const local_rank,
                                             size_t const world_size, int const tidx, int const bidx) {
    // After this function, at least one block in each GPU has reached the barrier
    if (tidx < world_size) {
        // we can think of signals having the shape [world_size, world_size]
        // Dimension 0 is the "listening" dimension, dimension 2 is "emitting" dimension

        // Block 0 broadcasts its flag (local_rank on emitting dimension) to all receivers
        if (bidx == 0) {
            signals[tidx][local_rank] = flag;
        }

        // All blocks check that corresponding block 0 on other GPUs have set the flag
        // No deadlock because block #0 is always the first block started
        uint32_t volatile *my_signals = signals[local_rank];
        while (my_signals[tidx] != flag) {
        }
    }

    __syncthreads();
}

__inline__ __device__ void block_barrier(uint32_t **signals, uint32_t const flag, size_t const local_rank,
                                         size_t const world_size, int const tidx, int const bidx) {
    // After this function, the block of id == bidx of each GPU has reached the barrier
    if (tidx < world_size) {
        // we can think of signals having the shape [world_size, num_blocks, world_size]
        // (+ an offset on dim 1 to account for flags used in multi_gpu_barrier)
        // Dimension 0 is the "listening" dimension, dimension 2 is "emitting" dimension

        // Block broadcast its flag (local_rank on emitting dimension) to all receivers
        uint32_t flag_block_offset = world_size + bidx * world_size;
        st_flag_release(flag, signals[tidx] + flag_block_offset + local_rank);

        // Blocks check that corresponding blocks on other GPUs have also set the flag
        uint32_t *peer_barrier_d = signals[local_rank] + flag_block_offset + tidx;
        while (ld_flag_acquire(peer_barrier_d) != flag) {
        }
    }

    __syncthreads();
}

template <typename T, int RANKS_PER_NODE, bool COPY_INPUT = true, bool PUSH_MODE = false>
static __global__ void oneShotAllReduceKernel(AllReduceParams params) {
    printf("oneShotAllReduceKernel\n");
    // Suppose that two GPUs participate in the AR exchange, and we start four blocks.
    // The message is partitioned into chunks as detailed below:
    //               message
    //       |-------------------|
    // GPU 0 | B0 | B1 | B2 | B3 |
    // GPU 1 | B0 | B1 | B2 | B3 |
    //
    // Here the step-by-step behavior of one block:
    // 1. B0 copies the chunk it  is responsible for, from local_input to shareable buffer
    // 2. B0 on GPU 0 and B0 on GPU 1 wait for each other (block_barrier)
    // 3. B0 on GPU 0 pull and sum the chunk from GPU 1, writes the result to local_output
    //
    // With COPY_INPUT == false, skip step 1. and use gpu_barrier instead of block barrier during step 2.
    // We only to know if the other GPU as arrived at the AR kernel, that would mean that data is ready
    //
    // With PUSH_MODE, we consider that the shared buffer is of size:
    // params.peer_comm_buffer_ptrs: [world_size, world_size, message_size]
    //
    // Here the step-by-step behavior of one block:
    // 1. B0 push the chunk is it responsible for into all other GPUs:
    //    params.peer_comm_buffer_ptrs[:, local_gpu, B0 slice]
    // 2. block sync so the block is shared by other GPUs
    // 3. Reduce along second dimension params.peer_comm_buffer_ptrs[local_gpu, :, B0 slice]

    int const bidx = blockIdx.x;
    int const tidx = threadIdx.x;

    // The number of elements packed into one for comms
    static constexpr int PACKED_ELTS = 16 / sizeof(T);
    using PackedStruct = typename PackedOn16Bytes<T>::Type;

    T const *local_input_buffer = reinterpret_cast<T const *>(params.local_input_buffer_ptr);
    T *local_shared_buffer = reinterpret_cast<T *>(params.peer_comm_buffer_ptrs[params.local_rank]);
    T *local_output_buffer = reinterpret_cast<T *>(params.local_output_buffer_ptr);

    // Start and end offsets of the thread
    size_t const chunk_start = bidx * params.elts_per_block + tidx * PACKED_ELTS;
    size_t const chunk_end = std::min((bidx + 1) * params.elts_per_block, params.elts_total);

    T *buffers[RANKS_PER_NODE];
#pragma unroll
    for (int ii = 0; ii < RANKS_PER_NODE; ++ii) {
        // buffers[0] is always the local buffers. Helps load balancing reads.
        int rank = (params.local_rank + ii) % RANKS_PER_NODE;
        buffers[ii] = reinterpret_cast<T *>(params.peer_comm_buffer_ptrs[rank]);
    }

    if constexpr (PUSH_MODE || COPY_INPUT) {
        // Copy from local buffer to shareable buffer
        for (size_t iter_offset = chunk_start; iter_offset < chunk_end; iter_offset += blockDim.x * PACKED_ELTS) {
            if constexpr (PUSH_MODE) {
#pragma unroll
                for (int ii = 0; ii < RANKS_PER_NODE; ++ii) {
                    *reinterpret_cast<int4 *>(&buffers[ii][params.local_rank * params.elts_total + iter_offset]) =
                        *reinterpret_cast<int4 const *>(&local_input_buffer[iter_offset]);
                }
            } else {
                *reinterpret_cast<int4 *>(&local_shared_buffer[iter_offset]) =
                    *reinterpret_cast<int4 const *>(&local_input_buffer[iter_offset]);
            }
        }

        // wait for equivalent blocks of other GPUs to have copied data to their shareable buffer
        block_barrier(params.peer_barrier_ptrs_in, params.barrier_flag, params.local_rank, RANKS_PER_NODE, tidx, bidx);
    } else {
        // In the non-copy case, we assume that once the kernel has been started, data is ready to be consumed
        multi_gpu_barrier(params.peer_barrier_ptrs_in, params.barrier_flag, params.local_rank, RANKS_PER_NODE, tidx,
                          bidx);
    }

    // Each block accumulates the values from the different GPUs on the same node.
    for (size_t iter_offset = chunk_start; iter_offset < chunk_end; iter_offset += blockDim.x * PACKED_ELTS) {
        // Iterate over the different ranks/devices on the node to load the values.
        PackedStruct vals[RANKS_PER_NODE];
#pragma unroll
        for (int ii = 0; ii < RANKS_PER_NODE; ++ii) {
            if constexpr (PUSH_MODE) {
                vals[ii].packed =
                    *reinterpret_cast<int4 const *>(&buffers[params.local_rank][ii * params.elts_total + iter_offset]);
            } else {
                vals[ii].packed = *reinterpret_cast<int4 const *>(&buffers[ii][iter_offset]);
            }
        }

        // Sum the values from the different ranks.
        PackedStruct sums;
        sums.packed = {0, 0, 0, 0};
#pragma unroll
        for (int rank = 0; rank < RANKS_PER_NODE; ++rank) {
            // Always reduce from rank 0 to ensure stable reduce order.
            int ii = (rank + RANKS_PER_NODE - params.local_rank) % RANKS_PER_NODE;
            sums.packed = add128b(sums, vals[ii]);
        }

        // Store to the destination buffer.
        *reinterpret_cast<int4 *>(&local_output_buffer[iter_offset]) = sums.packed;
    }
}

template <typename T, int RANKS_PER_NODE, bool COPY_INPUT = true, bool PUSH_MODE = false>
static __global__ void twoShotAllReduceKernel(AllReduceParams params) {
    // Suppose that two GPUs participate in the AR exchange, and we start two blocks.
    // The message is partitioned into chunks as detailed below:
    //               message
    //       |-------------------|
    //       |--GPU 0--|--GPU 1--| (GPU responsibility parts)
    // GPU 0 | B0 | B1 | B0 | B1 |
    // GPU 1 | B0 | B1 | B0 | B1 |
    //
    // Here the step-by-step behavior of one block:
    // 1. B0 copies all chunks is it responsible for, from local_input to shareable buffer
    // 2. B0 on GPU 0 and B0 on GPU 1 wait for each other (block_barrier #0)
    // 3. B0 on GPU 0 gather and sum the B0 chunks from GPU 1, that are in the GPU 0 responsibility
    //    part (the first half of the message, see GPU responsibility row above)
    // 3bis. Likewise, B0 on GPU 1 copies and sum the chunks for GPU 0,
    //       where GPU 1 is responsible: the second half of the message.
    // 4. B0 on GPU 0 and B0 on GPU 1 wait for each other (block_barrier #1)
    // 5. B0 writes result to local_output. It gathers each chunk from its responsible GPU.
    //    For example, here it reads the first chunk from GPU 0 and second chunk from GPU 1.
    //
    // With COPY_INPUT == false, skip step 1. and use gpu_barrier instead of block barrier during step 2.
    // We only to know if the other GPU as arrived at the AR kernel, that would mean that data is ready
    // to be read.
    //
    // Note that compared to one-shot, one block (CTA) writes multiple input chunks and write multiple output chunks.
    // However, it's only responsible for the summation of a single chunk.
    //
    // With PUSH_MODE, we consider that the shared buffer is of size:
    // params.peer_comm_buffer_ptrs: [world_size, world_size, message_size / world_size]
    //
    // Here the step-by-step behavior of one block:
    // 1. B0 push the chunks is it responsible for into the corresponding GPUs:
    //    params.peer_comm_buffer_ptrs[target_gpu, local_gpu, current B0 slice]
    // 2. block sync so the blocks have been shared by other GPUs
    // 3. Reduce along second dimension params.peer_comm_buffer_ptrs[local_gpu, :, B0 slice]
    // 4. block barrier (corresponding blocks have finished reduction)
    // 5. pull and write on local buffer, by reading params.peer_comm_buffer_ptrs[:, 0, B0 slice] (reduction result is
    //    written at index 0 of 2nd dim)

    int const bidx = blockIdx.x;
    int const tidx = threadIdx.x;

    // The number of elements packed into one for comms
    static constexpr int PACKED_ELTS = 16 / sizeof(T);
    using PackedType = typename PackedOn16Bytes<T>::Type;

    T const *local_input_buffer = reinterpret_cast<T const *>(params.local_input_buffer_ptr);
    T *local_shared_buffer = reinterpret_cast<T *>(params.peer_comm_buffer_ptrs[params.local_rank]);
    T *local_output_buffer = reinterpret_cast<T *>(params.local_output_buffer_ptr);

    size_t const chunk_start = bidx * params.elts_per_block + tidx * PACKED_ELTS;
    size_t const chunk_end = min(chunk_start + params.elts_per_block, params.elts_per_rank);

    T *buffers[RANKS_PER_NODE];
    int ranks[RANKS_PER_NODE];
#pragma unroll
    for (int ii = 0; ii < RANKS_PER_NODE; ++ii) {
        // A mapping of the ranks to scatter reads as much as possible
        int rank = (params.local_rank + ii) % RANKS_PER_NODE;
        ranks[ii] = rank;
        buffers[ii] = reinterpret_cast<T *>(params.peer_comm_buffer_ptrs[rank]);
    }

    if constexpr (PUSH_MODE || COPY_INPUT) {
        // Copy all blocks from local buffer to shareable buffer
        for (size_t local_offset = chunk_start; local_offset < chunk_end; local_offset += blockDim.x * PACKED_ELTS) {
#pragma unroll
            for (int ii = 0; ii < RANKS_PER_NODE; ++ii) {
                size_t offset_rank = ii * params.elts_per_rank + local_offset;
                if (offset_rank >= params.elts_total) {
                    continue;
                }

                if constexpr (PUSH_MODE) {
                    *reinterpret_cast<int4 *>(&buffers[ii][params.local_rank * params.elts_per_rank + local_offset]) =
                        *reinterpret_cast<int4 const *>(&local_input_buffer[offset_rank]);
                } else {
                    *reinterpret_cast<int4 *>(&local_shared_buffer[offset_rank]) =
                        *reinterpret_cast<int4 const *>(&local_input_buffer[offset_rank]);
                }
            }
        }
        block_barrier(params.peer_barrier_ptrs_in, params.barrier_flag, params.local_rank, RANKS_PER_NODE, tidx, bidx);
    } else {
        // In the non-copy case, we assume that once the kernel has been started, data is ready to be consumed
        multi_gpu_barrier(params.peer_barrier_ptrs_in, params.barrier_flag, params.local_rank, RANKS_PER_NODE, tidx,
                          bidx);
    }

    // Each block accumulates the values from the different GPUs on the same node.
    for (size_t local_offset = chunk_start; local_offset < chunk_end; local_offset += blockDim.x * PACKED_ELTS) {
        size_t const responsible_block_offset = local_offset + params.rank_offset;

        // Iterate over the different ranks/devices on the node to load the values.
        PackedType vals[RANKS_PER_NODE];
#pragma unroll
        for (int ii = 0; ii < RANKS_PER_NODE; ++ii) {
            if constexpr (PUSH_MODE) {
                vals[ii].packed =
                    *reinterpret_cast<int4 const *>(&local_shared_buffer[ii * params.elts_per_rank + local_offset]);
            } else {
                vals[ii].packed = *reinterpret_cast<int4 const *>(&buffers[ii][responsible_block_offset]);
            }
        }

        // Sum the values from the different ranks.
        PackedType sums;
        sums.packed = {0, 0, 0, 0};
#pragma unroll
        for (int rank = 0; rank < RANKS_PER_NODE; ++rank) {
            // Always reduce from rank 0 to ensure stable reduce order.
            int ii = (rank + RANKS_PER_NODE - params.local_rank) % RANKS_PER_NODE;
            sums.packed = add128b(sums, vals[ii]);
        }

        // Store to the local buffer.
        if constexpr (PUSH_MODE) {
            *reinterpret_cast<int4 *>(&local_shared_buffer[local_offset]) = sums.packed;
        } else {
            *reinterpret_cast<int4 *>(&local_shared_buffer[responsible_block_offset]) = sums.packed;
        }
    }

    block_barrier(params.peer_barrier_ptrs_out, params.barrier_flag, params.local_rank, RANKS_PER_NODE, tidx, bidx);

    // Gather all needed elts from other intra-node ranks
    for (size_t local_offset = chunk_start; local_offset < chunk_end; local_offset += blockDim.x * PACKED_ELTS) {
#pragma unroll
        for (int ii = 0; ii < RANKS_PER_NODE; ++ii) {
            // use round-robin gathering from other ranks
            size_t offset_rank = ranks[ii] * params.elts_per_rank + local_offset;
            if (offset_rank >= params.elts_total) {
                continue;
            }

            if constexpr (PUSH_MODE) {
                *reinterpret_cast<int4 *>(&local_output_buffer[offset_rank]) =
                    *reinterpret_cast<int4 *>(&buffers[ii][local_offset]);
            } else {
                *reinterpret_cast<int4 *>(&local_output_buffer[offset_rank]) =
                    *reinterpret_cast<int4 *>(&buffers[ii][offset_rank]);
            }
        }
    }
}

bool configurationSupported(AllReduceStrategyType algo, size_t msg_size, size_t n_ranks, onnxruntime::MLDataType type) {
    size_t elts_per_thread = 16 / type->Size();
    int const msg_align = (algo == AllReduceStrategyType::TWOSHOT) ? n_ranks * elts_per_thread : elts_per_thread;
    bool supported_algo = (algo == AllReduceStrategyType::ONESHOT || algo == AllReduceStrategyType::TWOSHOT);
    return supported_algo && (msg_size % msg_align == 0);
}

std::tuple<int, int> kernelLaunchConfig(AllReduceStrategyType algo, AllReduceParams &param, size_t elts_per_thread) {
    int blocks_per_grid = 1, threads_per_block = DEFAULT_BLOCK_SIZE;

    switch (algo) {
    case AllReduceStrategyType::ONESHOT: {
        ORT_ENFORCE(param.elts_total % elts_per_thread == 0);
        size_t const total_threads = roundUp(param.elts_total / elts_per_thread, WARP_SIZE);
        threads_per_block = std::min(DEFAULT_BLOCK_SIZE, total_threads);
        blocks_per_grid = std::min(static_cast<size_t>(MAX_ALL_REDUCE_BLOCKS),
                                   divUp(total_threads, static_cast<size_t>(threads_per_block)));
        param.elts_per_block = roundUp(divUp(param.elts_total, static_cast<size_t>(blocks_per_grid)), elts_per_thread);
        break;
    }
    case AllReduceStrategyType::TWOSHOT: {
        ORT_ENFORCE(param.elts_total % (elts_per_thread * param.ranks_per_node) == 0);
        size_t const total_threads = roundUp(param.elts_total / (elts_per_thread * param.ranks_per_node), WARP_SIZE);

        /*
        threads_per_block = std::min(DEFAULT_BLOCK_SIZE, total_threads);
        blocks_per_grid = std::min(static_cast<size_t>(MAX_ALL_REDUCE_BLOCKS), divUp(total_threads, threads_per_block));
        */

        while (total_threads % blocks_per_grid != 0 || total_threads / blocks_per_grid > DEFAULT_BLOCK_SIZE) {
            blocks_per_grid += 1;
        }

        threads_per_block = total_threads / blocks_per_grid;

        // NOTE: need to adjust here
        if (blocks_per_grid > MAX_ALL_REDUCE_BLOCKS) {
            size_t iter_factor = 1;
            while (blocks_per_grid / iter_factor > MAX_ALL_REDUCE_BLOCKS || blocks_per_grid % iter_factor) {
                iter_factor += 1;
            }
            blocks_per_grid /= iter_factor;
        }
        param.elts_per_rank = param.elts_total / param.ranks_per_node;
        param.rank_offset = param.local_rank * param.elts_per_rank;
        param.elts_per_block =
            roundUp(divUp(param.elts_per_rank, static_cast<size_t>(blocks_per_grid)), elts_per_thread);
        break;
    }
    default:
        ORT_THROW("Algorithm not supported here.");
    }

    return std::make_tuple(blocks_per_grid, threads_per_block);
}

template <typename T, int RANKS_PER_NODE, bool PUSH_MODE = false, bool USE_MEMCPY = false>
void AllReduceDispatchMemcpy(AllReduceStrategyType algo, AllReduceStrategyConfig config, AllReduceParams &param,
                             cudaStream_t stream) {
    ORT_ENFORCE(!(USE_MEMCPY && PUSH_MODE), "Memcpy cannot be used with PUSH_MODE.");
    size_t elts_per_thread = 16 / sizeof(T);
    auto [blocks_per_grid, threads_per_block] = kernelLaunchConfig(algo, param, elts_per_thread);
    std::cout << "blocks_per_grid: " << blocks_per_grid << ", threads_per_block: " << threads_per_block << std::endl;

    if (USE_MEMCPY) {
        std::cout << "cudaMemcpyAsync()" << std::endl;
        cudaMemcpyAsync(param.peer_comm_buffer_ptrs[param.local_rank], param.local_input_buffer_ptr,
                        param.elts_total * sizeof(T), cudaMemcpyDeviceToDevice, stream);
    }

    if (algo == AllReduceStrategyType::ONESHOT) {
        std::cout << "one shot kernel" << std::endl;
        oneShotAllReduceKernel<T, RANKS_PER_NODE, !USE_MEMCPY, PUSH_MODE>
            <<<blocks_per_grid, threads_per_block, 0, stream>>>(param);
        std::cout << "one shot kernel done" << std::endl;
    } else {
        twoShotAllReduceKernel<T, RANKS_PER_NODE, !USE_MEMCPY, PUSH_MODE>
            <<<blocks_per_grid, threads_per_block, 0, stream>>>(param);
    }
}

template <typename T, int RANKS_PER_NODE, bool PUSH_MODE = false>
void AllReduceDispatchPushMode(AllReduceStrategyType algo, AllReduceStrategyConfig config, AllReduceParams &param,
                               cudaStream_t stream) {
    if (static_cast<std::underlying_type_t<AllReduceStrategyConfig>>(config) &
        static_cast<std::underlying_type_t<AllReduceStrategyConfig>>(AllReduceStrategyConfig::USE_MEMCPY)) {
        std::cout << "USE_MEMCPY" << std::endl;
        AllReduceDispatchMemcpy<T, RANKS_PER_NODE, PUSH_MODE, true>(algo, config, param, stream);
    } else {
        std::cout << "NOT_USE_MEMCPY" << std::endl;
        AllReduceDispatchMemcpy<T, RANKS_PER_NODE, PUSH_MODE, false>(algo, config, param, stream);
    }
}

template <typename T, int RANKS_PER_NODE> //, bool USE_MEMCPY = false, bool PUSH_MODE = false>
void AllReduceDispatchRanksPerNode(AllReduceStrategyType algo, AllReduceStrategyConfig config, AllReduceParams &param,
                                   cudaStream_t stream) {
    if (static_cast<std::underlying_type_t<AllReduceStrategyConfig>>(config) &
        static_cast<std::underlying_type_t<AllReduceStrategyConfig>>(AllReduceStrategyConfig::PUSH_MODE)) {
        std::cout << "PUSH_MODE" << std::endl;
        AllReduceDispatchPushMode<T, RANKS_PER_NODE, true>(algo, config, param, stream);
    } else {
        std::cout << "NOT_PUSH_MODE" << std::endl;
        AllReduceDispatchPushMode<T, RANKS_PER_NODE, false>(algo, config, param, stream);
    }
}

template <typename T>
void AllReduceDispatchType(AllReduceParams &param, AllReduceStrategyType strat, AllReduceStrategyConfig config,
                           cudaStream_t stream) {
    switch (param.ranks_per_node) {
    case 2:
        AllReduceDispatchRanksPerNode<T, 2>(strat, config, param, stream);
        break;
    case 4:
        AllReduceDispatchRanksPerNode<T, 4>(strat, config, param, stream);
        break;
    case 6:
        AllReduceDispatchRanksPerNode<T, 6>(strat, config, param, stream);
        break;
    case 8:
        AllReduceDispatchRanksPerNode<T, 8>(strat, config, param, stream);
        break;
    default:
        ORT_THROW("Custom all reduce only supported on {2, 4, 6, 8} GPUs per node.");
    }
}

AllReduceParams AllReduceParams::deserialize(int32_t const *buffer, size_t tpSize, size_t tpRank) {
    void *const *buffer_ptrs = reinterpret_cast<void *const *>(buffer);
    AllReduceParams params;

    for (int i = 0; i < tpSize; ++i) {
        params.peer_comm_buffer_ptrs[i] = buffer_ptrs[i];
    }
    for (int i = 0; i < tpSize; ++i) {
        params.peer_barrier_ptrs_in[i] = reinterpret_cast<uint32_t *>(buffer_ptrs[tpSize + i]);
    }
    for (int i = 0; i < tpSize; ++i) {
        params.peer_barrier_ptrs_out[i] = reinterpret_cast<uint32_t *>(buffer_ptrs[2 * tpSize + i]);
    }
    params.barrier_flag = 0;
    params.ranks_per_node = tpSize;
    params.rank = tpRank;
    params.local_rank = tpRank;

    return params;
}

void customAllReduce(AllReduceParams &params, onnxruntime::MLDataType dataType, AllReduceStrategyType strat,
                     AllReduceStrategyConfig config, cudaStream_t stream) {
    ORT_ENFORCE(configurationSupported(strat, params.elts_total, params.ranks_per_node, dataType),
                "Custom all-reduce configuration unsupported");

    if (dataType == onnxruntime::DataTypeImpl::GetType<float>()) {
        AllReduceDispatchType<float>(params, strat, config, stream);
    } else if (dataType == onnxruntime::DataTypeImpl::GetType<onnxruntime::MLFloat16>()) {
        AllReduceDispatchType<half>(params, strat, config, stream);
    } else {
        ORT_THROW("Unsupported dataType for customAllReduce");
    }
}

} // namespace ort_trtllm
