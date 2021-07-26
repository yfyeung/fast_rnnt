#include <torch/extension.h>
#include <c10/cuda/CUDAStream.h>  // for getCurrentCUDAStream()
#include <cooperative_groups.h>





/*
  Tiled summing reduction within a warp.  Requires that the thread-block
  be 1-dimensional, i.e.  blockDim.y == blockDim.z == 1.  Does not use
  __syncthreads, so it is safe to call in a subset of threads.
  TODO: we can in principle do this without a buffer, using __shfl_down()
  (see here https://sodocumentation.net/cuda/topic/6566/parallel-reduction--e-g--how-to-sum-an-array-)
  if CC >= 3.0.

  Args:
      threads_per_tile:  Must be a power of 2 in the interval [1,32].  Summation is
                         within blocks of threads of this size.
       buf:              Pointer to the start of a __shared__ buffer of size
                         blockDim.x, to be used as a temporary within this function.
       val:              The value to be summed
   Return:
       Threads where threadIdx.x % threads_per_tile == 0 will return the sum:
         \sum_{i=0}^{threads_per_tile-1} [val in thread threadIdx.x + i]
       The return value in other threads is undefined.
 */
template <typename scalar_t>
__forceinline__ __device__ scalar_t tiled_warp_reduce_sum(int threads_per_tile,
                                                          __volatile__ scalar_t *buf,
                                                          scalar_t val) {
  // Each iteration halves the number of active threads
  // Each thread adds its partial sum[i] to sum[lane+i]
  for (int i = threads_per_tile / 2; i > 0; i /= 2) {
    buf[threadIdx.x] = val;
    if (threadIdx.x % threads_per_tile < i)
      val += buf[threadIdx.x + i];
  }
  return val; // Only threads with threadIdx.x % threads_per_tile == 0 will
              // return the full sums of their tiles.
}


/*
  Forward of mutual_information.  Each thread block handles blocks of (x, y) shape
  equal to (BLOCK_S_SIZE, BLOCK_T_SIZE), e.g. (4, 64).  Thread blocks loop over such
  blocks, but they might typically loop only once.  We sequentially launch groups of
  threads in such a way that thread-blocks within a group do not depend on each other.


  Template args:
      scalar_t: the floating-point type, e.g. float, double, maybe half.

  Args:
      input:  input image, shape (B, C, T) where B is batch size, C is
              the number of channels and T is the time axis.  (For more-than-1d
              convolution setups, T would really be more than 1 axis, reshaped).
      params:  of shape (C, N+1) where N is the number of linear regions in the
               piecewise linear function; params[c][0] is l which is
               a log scale parameter that dictates how far apart
               the discontinuities in the piecewise linear function are,
               and params[c][n+1] for 0 <= n < N are the derivatives
               of the linear parts of the piecewise linear function.
               The discontinuities of the function are at:
                    exp(l) * [ -(N/2 - 1), -(N/2 - 2), ... (N/2 - 1) ]
      output:  The transformed input, shape (B , C, T)
      images_per_thread_block:  The number of images processed by each thread
               block.  The calling code must guarantee that this is a power
               of 2, and that EITHER:
                   THREADS_PER_BLOCK / images_per_thread_block >= T
               OR
                   images_per_thread_block == 1
                .. this is used for a small optimization.

    This kernel is allocated with `extern_buf` containing enough memory
    to store 2*N + 3 values of type scalar_t.

   The blockDim must equal (THREADS_PER_BLOCK, 1, 1)

   The requirements on the grid dimension are:
       gridDim.x == num-channels C (required)
   1 <=  gridDim.y <= B, where B is the number of blocks
       gridDim.z == 1
  When we invoke this kernel, we'll invoke it as:
   mutual_information_kernel<<<gridDim, blockDim, bytesShared, stream>>>
   where bytesShared is the number of bytes needed in `extern_buf`:
     bytesShared = sizeof(shared_t) * (2N + 3)
    We also require N + 1 <= THREADS_PER_BLOCK.
 */
extern __shared__ int extern_buf[];

template <typename scalar_t,
          int BLOCK_S_SIZE,   // e.g. BLOCK_S_SIZE == 4; power of 2
          int BLOCK_T_SIZE>   // e.g. BLOCK_T_SIZE == 64; power of 2.
                              // BLOCK_T_SIZE * 4 must equal num_threads; and must be >= 128, so BLOCK_T_SIZE >= 32 is required.
                              // (Note: this 4 is unrelated to BLOCK_S_SIZE but can be viewed as 1<<2,
                              // where 2 is the loop unrolling factor).
__global__
void mutual_information_kernel(
    torch::PackedTensorAccessor32<scalar_t, 3> px,   // B, S, T, i.e. batch, x_seq_length, y_seq_length
    torch::PackedTensorAccessor32<scalar_t, 3> py,   // B, S, T, as above
    torch::PackedTensorAccessor32<scalar_t, 3> p,    // B, S, T, as above.  This is an output.
    torch::PackedTensorAccessor32<scalar_t, 2> boundary,  // B, 4;  or 0, 0 if boundaries are the defaults (0, 0, S, T)
    int iter) {    // This kernel is sequentially called with 'iter' = 0, 1, 2 and so on, up to:
                   //    (S+BLOCK_S_SIZE-1)/BLOCK_S_SIZE + (T+BLOCK_T_SIZE-1)/BLOCK_T_SIZE  - 1
                   // so that each group depends on the previous group...

  const int block_dimx = BLOCK_T_SIZE * 4;  // known at compile time.
  assert(blockDim.x == block_dimx);

  const int B = px.size(0),
      S = px.size(1),
      T = py.size(2);
  // num_s_blocks and num_t_blocks are the number of blocks we need to cover the
  // array of size (S, T) with blocks of this size, in the s and t directions
  // respectively.
  const int num_s_blocks = (S + BLOCK_S_SIZE - 1) / BLOCK_S_SIZE,
      num_t_blocks = (T + BLOCK_T_SIZE - 1) / BLOCK_T_SIZE;
  // num_blocks_this_iter is an upper bound on the number of blocks that might
  // be active on this iteration.  We go from the bottom left of the image
  // so that on iter == 0 we process only one block with block-index (0, 0)
  // then on iter == 1 we process block-indexes (1, 0) and (0, 1); and then on iter==2
  // we process (2, 0), (1, 1) and (0, 2); and so on.  We also will never have more
  // than `num_s_blocks` blocks (We'll never have more than num_t_blocks either, but
  // the numbering we use corresponds to s and not t, so if we hit the num_t_blocks limit,
  // the lowest-numbered blocks on s would just not be active and we'll 'continue' below).
  int num_blocks_this_iter = min(iter + 1, num_s_blocks);


  __shared__ scalar_t px_buf[BLOCK_S_SIZE][BLOCK_T_SIZE],
      py_buf[BLOCK_S_SIZE][BLOCK_T_SIZE],
      p_buf[BLOCK_S_SIZE + 1][BLOCK_T_SIZE + 1];  // 1st row/col of p_buf
                                                  // correspond to the previous
                                                  // blocks, or an edge case.

  __shared__ boundary_buf[4];

  // batch_block_iter iterates over both batch elements (index b), and block
  // indexes
  for (int batch_block_iter = blockIdx.x;
       batch_block_iter < B * num_blocks_this_iter;
       batch_block_iter += gridDim.x) {
    int b = batch_block_iter % B,
        block = batch_block_iter / B;

    int s_block_begin = block * BLOCK_S_SIZE,
        t_block_begin = (iter  - block) * BLOCK_T_SIZE;

    bool is_origin_block = (s_block_begin * t_block_begin == 0);

    int s_end, t_end;  // s_end and t_end are the end points (last-plus-one) of the entire sequence.
    if (boundary.size(0) == 0) {
      s_end = S;
      t_end = T;
    } else {
      if (threadDim.x < 4)
        boundary_buf[threadDim.x] = boundary[b][threadDim.x];
      __syncthreads();
      int s_begin = boundary_buf[0],
          t_begin = boundary_buf[1];
      s_end = boundary_buf[2];
      t_end = boundary_buf[3];
      s_block_begin += s_begin;
      t_block_begin += t_begin;
    }

    // block_S and block_T are the actual sizes of this block, up to
    // (BLOCK_S_SIZE, BLOCK_T_SIZE) but possibly truncated if we
    // are towards the end of the sequence.
    int block_S = min(BLOCK_T_SIZE, s_end - s_block_begin),
        block_T = min(BLOCK_S_SIZE, t_end - t_block_begin);

    if (block_S <= 0 || block_T <= 0)
      continue;


    // Load px_buf and py_buf.  We exponentiate; the assumption is that they
    // won't overflow or underflow!  If they overflow we'll detect it later!

    for (int i = threadDim.x; i < BLOCK_S_SIZE * BLOCK_T_SIZE; i += block_dimx) {
      int t = i % BLOCK_T_SIZE, s = i / BLOCK_T_SIZE;
      if (s < block_S && t < block_T) {
        px_buf[s][t] = exp(px[b][s + s_block_begin][t + t_block_begin]);
        py_buf[s][t] = exp(py[b][s + s_block_begin][t + t_block_begin]);
      } else { // Not necessary?  We'll see
        px_buf[s][t] = 0.0;
        py_buf[s][t] = 0.0;
      }
    }

    // Load the 1st row and column of p_buf (except element[0][0] is not needed).
    if (threadIdx.x < 64) {  // 64 == warp size...
      if (threadIdx.x <= BLOCK_S_SIZE) {
        // this s and t are offsets relative to the block start
        int s = threadIdx.x - 1,
            t = -1;
        if (static_cast<unsigned int>(s + s_block_begin) < static_cast<unsigned int>(block_S) &&
            static_cast<unsigned int>(t + t_block_begin) < static_cast<unsigned int>(block_T))
          p_buf[threadIdx.x][0] = p[s + s_block_begin][s + t_block_begin];
        else
          p_buf[threadIdx.x][0] = -infinity;
      }
    } else {
      if (threadIdx.x - 64 <= BLOCK_T_SIZE) {
        int i = threadIdx.x - 64,
            t = i - 1,
            s = -1;
        if (static_cast<unsigned int>(s + s_block_begin) < static_cast<unsigned int>(block_S) &&
            static_cast<unsigned int>(t + t_block_begin) < static_cast<unsigned int>(block_T))
          p_buf[0][i] = p[s + s_block_begin][s + t_block_begin];
        else {
          p_buf[0][i] = (is_origin_block && i == 1 ? 1.0 /
              -infinity;
        }
      }




  }



      N = params.size(1) - 1,
      K = N / 2;  // Note: N and K are powers of 2, with K >= 1.

  const int c = blockIdx.x;  // c is channel index

  scalar_t *y_vals = (scalar_t*) extern_buf,  // [N], actually there are 3
                                              // spaces between here and
                                              // `params_buf` for storing scale
                                              // and inv_scale and l == params[c][0].
      *params_buf = (scalar_t*) y_vals + 3 + N;  // [N].  params_buf[n] ontains params[c][n-1].
                                                 //  params_buf[-1] contains params[c][0] == log of scale;
                                                 // params_buf[-2] contains scale, params_buf[-3]
                                                 // contains inv_scale.
  // Load parameters
  if (threadIdx.x <= N)
    params_buf[threadIdx.x - 1] = params[c][threadIdx.x];
  __syncthreads();

  if (threadIdx.x == 0) {
    scalar_t scale = exp(params_buf[-1]);
    params_buf[-2] = scale;
    params_buf[-3] = 1.0 / scale;
  }
  __syncthreads();

  if (threadIdx.x == 0) {
    scalar_t scale = params_buf[-2],
        sum_positive = 0.0;
    for (int i = 0; i < K; i++) {
      // params_buf is indexed with an index one less than params.
      scalar_t pos_scaled_param = params_buf[K + i] * scale;
      y_vals[K + i] = sum_positive - pos_scaled_param * i;
      sum_positive += pos_scaled_param;
    }
  } else if (threadIdx.x == 64) {
    scalar_t scale = params_buf[-2],
        sum_negative = 0.0;
    for (int i = 0; i < K; i++) {
      scalar_t neg_scaled_param = params_buf[K - 1 - i] * scale;
      sum_negative -= neg_scaled_param;
      y_vals[K - i - 1] = sum_negative + neg_scaled_param * (i + 1);
    }
  }
  __syncthreads();

  scalar_t inv_scale = params_buf[-3];

  int T_inc = THREADS_PER_BLOCK / images_per_thread_block,
      b_offset = threadIdx.x / T_inc,  // offset within batch
      t_start = threadIdx.x % T_inc;

  for (int b = blockIdx.y * images_per_thread_block + b_offset; b < B;
       b += gridDim.y * images_per_thread_block) {
    // We do "t += THREADS_PER_BLOCK" instead of t += (THREADS_PER_BLOCK /
    // images_per_thread_block) as a small optimization because the only case we
    // really need to loop is when images_per_thread_block == 1:a we only let
    // images_per_thread_block > 1 if T * images_per_thread_block <=
    // THREADS_PER_BLOCK.
    for (int t = t_start; t < T; t += THREADS_PER_BLOCK) {
      scalar_t this_input = input[b][c][t],
          x = this_input * inv_scale + K;
      if (x < 0) x = 0;
      else if (x >= N) x = N - 1;
      // C++ rounds toward zero.
      int n = (int) x;
      // OK, at this point, 0 <= min < N.  Versus the CPU code, we removed the
      // factor of 'scale' because params_buf already has that factor.
      output[b][c][t] = this_input * params_buf[n] + y_vals[n];
    }
  }
}



/*
  Summing reduction within a one-dimensional thread block, but with a
  stride of N, so that we separately sum up the values of all threads with
  threadIdx.x % N == 0, with threadIdx.x % N == 1, and so on.  At the end,
  threads with 0 <= threadIdx.x < N contain the sums.

  So this is like tiled summing reduction except that the tiles are
  interspersed with each other.


  Args:
       N:                The number we sum modulo (must be a power of 2 with
                         1 <= N <= blockDim.x), i.e. all threads with
                         threadIdx.x % N == n for some 0 <= n < N have `val` summed.
       buf:              Pointer to the start of a __shared__ buffer of size
                         blockDim.x, to be used as a temporary within this function.
       val:              The value to be summed
  Return:
       Threads where threadIdx.x < N will return the sums (over the threads with
       the same value of threadIdx.x % N);
       the return value in other threads is undefined.
 */
template <typename scalar_t>
__forceinline__ __device__ scalar_t strided_reduce_sum(int N,
                                                       __volatile__ scalar_t *buf,
                                                       scalar_t val) {
  // Each iteration halves the number of active threads
  // Each thread adds its partial sum[i] to sum[lane+i]
  for (int i = blockDim.x / 2; i >= N; i /= 2) {
    buf[threadIdx.x] = val;
    __syncthreads();
    if (threadIdx.x < i)
      val += buf[threadIdx.x + i];
  }
  return val; // Only threads with threadIdx.x < N will return the full sums of
              // their groups.
}

/*
  Backward of mutual_information.  Each thread group handles a single channel (channel
  c = blockIdx.x); the gridDim is (C, nb, 1) where 1 <= nb <= B (nb relates to the
  image within the batch).

  Template args:
      scalar_t: the floating-point type, e.g. float, double, maybe half.

  Args:
      input:  input image, shape (B, C, T) where B is batch size, C is
              the number of channels and T is the time axis.  (For more-than-1d
              convolution setups, T would really be more than 1 axis, reshaped).
      params: of shape (C, N+1) where N is the number of linear regions in the
              piecewise linear function; params[c][0] is l which is
              a log scale parameter that dictates how far apart
              the discontinuities in the piecewise linear function are,
              and params[c][n+1] for 0 <= n < N are the derivatives
              of the linear parts of the piecewise linear function.
              The discontinuities of the function are at:
                   exp(l) * [ -(N/2 - 1), -(N/2 - 2), ... (N/2 - 1) ]
      output:  The transformed input, shape (B , C, T)
      images_per_thread_block:  The number of images processed by each thread
               block.  The calling code must guarantee that this is a power
               of 2, and that EITHER:
                   (THREADS_PER_BLOCK / images_per_thread_block >= T  AND
                    THREADS_PER_BLOCK / images_per_thread_block >= N),
               OR
                   images_per_thread_block == 1
                .. this is used for a small optimization.

                ALSO,

    This kernel is allocated with `extern_buf` containing enough memory
    to store 2*N + 3 values of type scalar_t.

   The blockDim must equal (THREADS_PER_BLOCK, 1, 1)

   The requirements on the grid dimension are:
       gridDim.x == num-channels C (required)
   1 <=  gridDim.y <= B, where B is the number of blocks
       gridDim.z == 1
  When we invoke this kernel, we'll invoke it as:
   mutual_information_backward_kernel<<<gridDim, blockDim, bytesShared, stream>>>
   where bytesShared is the number of bytes needed in `extern_buf`:
     bytesShared = sizeof(shared_t) * (2N + 3)

   We also require that N <= THREADS_PER_BLOCK (for best performance,
   N should be quite small, like no larger than 8 or so).
   We also require 4 <= N <= 16 for this code!
   And we require that
      N <= (THREADS_PER_BLOCK / images_per_thread_block)
   (both sides will be powers of 2).. this ensures that blocks of threads
   summing the N values are always within the same image, which helps
   avoid a problem where some loops over 'b' would be done earlier
   than others, and we'd end up counting certain pixels twice as their
   output_grad would stay nonzero.


 */
template <typename scalar_t>
__global__
void mutual_information_backward_kernel(
    torch::PackedTensorAccessor32<scalar_t, 3> input,  // B, C, T, i.e. batch, channels, time
    torch::PackedTensorAccessor32<scalar_t, 2> params,  // C, N + 1
    torch::PackedTensorAccessor32<scalar_t, 3> output_grad, // B, C, T
    torch::PackedTensorAccessor32<scalar_t, 3> input_grad, // B, C, T
    // params_grad is of dim (gridDim.y, C, N + 1), we'll sum over dim 0.
    torch::PackedTensorAccessor32<scalar_t, 3> params_grad,
    int images_per_thread_block) {  // B, C, T

  const int B = input.size(0),
      C = input.size(1),
      T = input.size(2),
      N = params.size(1) - 1,
      K = N / 2;  // Note: N and K are powers fo 2, with K >= 1.

  const int c = blockIdx.x; // c is channel index

  scalar_t *y_vals = (scalar_t*) extern_buf,  // [N], actually there are three
                                              // spaces between here and
                                              // `params_buf` for storing scale
                                              // and inv_scale and l == params[c][0].
      *params_buf = (scalar_t*) y_vals + 3 + N;  // [N].  Contains parameters (not times scale!)
                                                 // Caution: contains params[c][1] through params[c][N],
                                                 // i.e. numbering is off by 1 versus params.
                                                 //  params_buf[-1] contains params[c][0] == log of scale;
                                                 // params_buf[-2] and params_buf[-3] contain scale and inv_scale.

  __shared__ scalar_t input_buf[THREADS_PER_BLOCK];  // input sequence
  __shared__ scalar_t output_grad_buf[THREADS_PER_BLOCK];
  __shared__ char n_buf[THREADS_PER_BLOCK];  // for each input in `input_buf`,
                                             // this stores the integer value 0
                                             // <= n < N which determines which
                                             // piece of the piecewise linear
                                             // function we are in.

  // Load parameters
  if (threadIdx.x <= N)
    params_buf[threadIdx.x - 1] = params[c][threadIdx.x];
  __syncthreads();

  if (threadIdx.x == 0) {
    scalar_t scale = exp(params_buf[-1]);
    params_buf[-2] = scale;
    params_buf[-3] = 1.0 / scale;
  }
  __syncthreads();

  if (threadIdx.x == 0) {
    scalar_t scale = params_buf[-2],
        sum_positive = 0.0;
    for (int i = 0; i < K; i++) {
      // params_buf is indexed with an index one less than params.
      scalar_t pos_scaled_param = params_buf[K + i] * scale;
      y_vals[K + i] = sum_positive - pos_scaled_param * i;
      sum_positive += pos_scaled_param;
    }
  } else if (threadIdx.x == 64) {
    scalar_t scale = params_buf[-2],
        sum_negative = 0.0;
    for (int i = 0; i < K; i++) {
      scalar_t neg_scaled_param = params_buf[K - i - 1] * scale;
      sum_negative -= neg_scaled_param;
      y_vals[K - i - 1] = sum_negative + neg_scaled_param * (i + 1);
    }
  }
  __syncthreads();


  // this_param_grad and this_y_grad pertain to the 'n' value (i.e. the n'th
  // linear interval) corresponding to n == threadIdx.x % N.  For example, if
  // threadIdx.x == 0, this thread's gradient corresponds to the left-most
  // linear interval.
  scalar_t this_param_grad = 0.0,
      this_y_vals_grad = 0.0;

  scalar_t inv_scale = params_buf[-3];

  int T_inc = THREADS_PER_BLOCK / images_per_thread_block,
      b_offset = threadIdx.x / T_inc;  // offset within batch

  for (int b = blockIdx.y * images_per_thread_block + b_offset; b < B;
       b += gridDim.y * images_per_thread_block) {

    // The following will loop just once if images_per_thread_block > 1.  If
    // images_per_thread_block == 1 and T > THREADS_PER_BLOCK, we will loop
    // multiple times.  We want to keep all threads active so that output_grad
    // will be set to zero for excess threads, and thus won't contribute to
    // this_params_grad or this_y_vals_grad.
    for (int t_offset = 0; t_offset < T; t_offset += THREADS_PER_BLOCK) {
      // The following is equivalent to:
      // int t = (threadIdx.x % T_inc) + t_offset;
      // given that T_inc is a power of 2 and t_offset >= THREADS_PER_BLOCK >= T_inc.
      int t = (threadIdx.x & (T_inc - 1)) | t_offset;

      scalar_t this_input = 0.0, this_output_grad;
      if (t < T) {
        this_output_grad = output_grad[b][c][t];
        this_input = input[b][c][t];
        input_buf[threadIdx.x] = this_input;
        output_grad_buf[threadIdx.x] = this_output_grad;
      }
      scalar_t x = this_input * inv_scale + K;
      if (x < 0) x = 0;
      else if (x >= N) x = N - 1;

      // The forward code did:
      // output[b][c][t] = this_input * params_buf[n] + y_vals[n];
      // We get the derivative for params and y_vals later.
      if (t < T) {
        int n = (int)x;   // C++ rounds toward zero.
        n_buf[threadIdx.x] = (char)n;
        input_grad[b][c][t] = this_output_grad * params_buf[n];
      } else {
        n_buf[threadIdx.x] = 255;
      }

      int this_block_start = threadIdx.x & ~(N-1),  // == N * (threadIdx.x / N),
                                                    // since N is power of 2
          this_n = threadIdx.x & (N-1); // == threadIdx.x % N.
      // this_n is the n value that this thread accumulates gradients for;
      // it is responsible for output_grads in the block of threads
      // from this_block_start to this_block_start+N-1.


      // __syncthreads();  // <- not really needed.
      // At this point there is an implicit within-warp
      // synchronization (Note: implicit warp synchronization is not considered
      // future-proof).  Threads above have written to n_buf, and threads below
      // will read from it; but we don't need to explicitly synchronize for now
      // because the reads/writes are among threads in a group of N threads with
      // (4 <= N <= 16); and 16 is less than the warp size which is 32 or 64.

      // src_indexes will contain up to 16 16-bit numbers, stored starting in its
      // least significant bits.  It will store all the offsets within this
      // block of N threads, whose chosen 'n' value equals this_n.
      uint64_t src_indexes = 0;
      // num_src is the number of numbers in `src_indexes`.  We need to store a
      // separate counter because zero is a valid index and if we are to support
      // N == 16 we don't have bits to spare in src_indexes to store some kind
      // of marker.
      int num_src = 0;

      // This loop always does at least N statements, but they should be
      // relatively fast ones since the computation per n value is minimal and
      // there is little I/O.  We are figuring out the subset of our block of N
      // elements, which this particular thread value is responsible for
      // (because they have n == this_n), and storing them in `src_indexes` and
      // `num_src`.
      for (int i = 0; i < N; i += 4) {
        uint32_t n_block_of_4 = *reinterpret_cast<uint32_t*>(n_buf + this_block_start + i);
        #pragma unroll
        for (int j = 0; j < 4; ++j) {
          // CUDA is little endian
          char n = (char)(n_block_of_4 >> (8*j));
          if (n == this_n) {
            // We require that N <= 16, so 4 bits is enough to store src_idx.
            src_indexes = (src_indexes << 4) | (i + j);
            ++num_src;
          }
          // Note: if, for out-of-range threads, we had values not in [0..N-1] in
          // n_buf they won't end up mattering even though they are read here,
          // because they won't equal this_n.  For values 0 <= n < N originating
          // in out-of-range threads, the value won't matter because the
          // corresponding value in output_grad_buf will be zero.
        }
      }

      // While num_src could theoretically be as large as N, the hope is that no
      // thread in any given warp actually loops that many times.  Once all
      // threads in the warp are finished looping, we can continue.  It is OK
      // for different warps to get out of sync here; we could be looping over a
      // number of images, and the hope is that different warps will reach the
      // end of the outer loop at around the same time because their variations
      // in speed will average out.
      for (; num_src > 0; --num_src, (src_indexes >>= 4)) {
        int src_thread = this_block_start | (src_indexes & 0xF);
        scalar_t src_output_grad = output_grad_buf[src_thread],
            src_input = input_buf[src_thread];
        assert(n_buf[src_thread] == this_n);
        n_buf[src_thread] = 0;
        // Backprop for: output = input * params_buf[n] + y_vals[n].
        // Here, n == this_n; this is how we selected these `src_idx` values.
        this_param_grad += src_output_grad * src_input;
        this_y_vals_grad += src_output_grad;
      }

      // TODO: remove the next lines
      assert(n_buf[threadIdx.x] == 0 || (unsigned char)n_buf[threadIdx.x] == 255);
      output_grad_buf[threadIdx.x] = 0.0;
    }
  }

  __syncthreads();  // sync threads because we are about to re-use
                    // output_grad_buf for reduction, and, later, input_buf.

  this_param_grad = strided_reduce_sum(N, output_grad_buf, this_param_grad);
  __syncthreads();
  this_y_vals_grad = strided_reduce_sum(N, output_grad_buf, this_y_vals_grad);

  __syncthreads();  // sync threads because we are about to re-use
                    // output_grad_buf as y_vals_grad_buf.

  // Re-use some buffers..
  scalar_t *params_grad_buf = input_buf + 1,  // [N]  ... but element [-1] will have deriv of scale.
      *y_vals_grad_buf = output_grad_buf;   // [N]

  if (threadIdx.x < N) {
    params_grad_buf[threadIdx.x] = this_param_grad;
    y_vals_grad_buf[threadIdx.x] = this_y_vals_grad;
  }
  __syncthreads(); // other threads are about to read params_grad_buf and
                   // y_vals_grad_buf.

  // This next block does backprop relating to `y_vals`.  Comparing with the CPU
  // version (call this the "reference code") is the best way to understand this
  // (this code is just a modification of that).  The main difference is we
  // modify the indexes into params and params_grad by -1, so the index
  // corresponds to the 'n' value; and element -1 of params_grad_buf will have
  // the deriv of the log scale.

  scalar_t l_grad;
  if (threadIdx.x == 0) {
    // Now do the backprop for the loop above where we set y_vals_a.  This could
    // be further optimized to replace the loop with a raking, but I doubt this
    // will have a huge effect on the runtime since K will be fairly small,
    // e.g. 4.
    scalar_t scale = params_buf[-2],
        scale_grad = 0.0,
        sum_positive_grad = 0.0;
    for (int i = K - 1; i >= 0; i--) {
      // Backprop for: sum_positive += pos_scaled_param;
      scalar_t pos_scaled_param_grad = sum_positive_grad;
      // Backprop for: y_vals[K + i] = sum_positive - pos_scaled_param * i;
      scalar_t y_grad_pos = y_vals_grad_buf[K + i];
      pos_scaled_param_grad -= i * y_grad_pos;
      sum_positive_grad += y_grad_pos;
      // Backprop for: pos_scaled_param = params_buf[K + i] * scale,
      params_grad_buf[K + i] += pos_scaled_param_grad * scale;
      scale_grad += pos_scaled_param_grad * params_buf[K + i];
    }
    // Backprop for: scale = exp(l), where l = params[c][0].
    l_grad = scale * scale_grad;
  } else if (threadIdx.x == 64) {
    // Now do the backprop for the loop above where we set y_vals.
    // Make this one threadIdx.x == 0 so it's possibly quicker to test
    //
    scalar_t scale = params_buf[-2],
        scale_grad = 0.0,
        sum_negative_grad = 0.0;
    for (int i = K - 1; i >= 0; i--) {
      // Backprop for: y_vals[K - i - 1] = sum_negative + neg_scaled_param * (i + 1):
      scalar_t y_grad_neg = y_vals_grad_buf[K - i - 1];
      sum_negative_grad += y_grad_neg;
      scalar_t neg_scaled_param_grad = y_grad_neg * (i + 1);
      // Backprop for: sum_negative -= neg_scaled_param;
      neg_scaled_param_grad -= sum_negative_grad;
      // Backprop for: neg_scaled_param = params_buf[K - i - 1] * scale;
      params_grad_buf[K - i - 1] += neg_scaled_param_grad * scale;
      scale_grad += neg_scaled_param_grad * params_buf[K - i - 1];
    }
    params_grad_buf[-1] = scale * scale_grad;
  }
  __syncthreads();

  if (threadIdx.x == 0) {
    params_grad_buf[-1] += l_grad;  // contribution to l grad from the "negative" branch
  }
  __syncthreads();
  if (threadIdx.x <= N) {
    params_grad[blockIdx.y][c][threadIdx.x] = params_grad_buf[threadIdx.x - 1];
  }
}




torch::Tensor mutual_information_cuda(torch::Tensor input,
                                  torch::Tensor params) {

  TORCH_CHECK(input.dim() == 3, "input must be 3-dimensional");
  TORCH_CHECK(params.dim() == 2, "params must be 2-dimensional.");
  TORCH_CHECK(params.size(1) >= 3 &&
              ((params.size(1) - 1) & (params.size(1) - 2)) == 0,
              "params.size(1) has invalid value, must be a power of 2 plus 1.");
  TORCH_CHECK(params.size(0) == input.size(1),
              "params vs input channels mismatch");

  TORCH_CHECK(input.device().is_cuda(), "Input must be a CUDA tensor");
  TORCH_CHECK(params.device().is_cuda(), "Params must be a CUDA tensor");


  const int B = input.size(0),
      C = input.size(1),
      T = input.size(2),
      N = params.size(1) - 1;

  auto scalar_t = input.scalar_type();
  auto opts = torch::TensorOptions().dtype(scalar_t).device(input.device());

  torch::Tensor output = torch::empty({B, C, T}, opts);

  if (C * B * T == 0)
    return output;

  int images_per_thread_block = 1;
  while (images_per_thread_block * 2 * T <= THREADS_PER_BLOCK)
    images_per_thread_block *= 2;

  int grid_dim_y = 1;
  // If the number of channels is quite small (<128) we can launch more thread
  // groups, splitting on the batch index.
  while (C * grid_dim_y < 128)
    grid_dim_y *= 2;

  // B_reduced is the max number of thread-groups per channel that would have
  // any work to do.  If grid_dim_y is more than this, we reduce it to avoid
  // launching kernels with nothing to do.
  int B_reduced = (B + images_per_thread_block - 1) / images_per_thread_block;
  if (grid_dim_y > B_reduced)
    grid_dim_y = B_reduced;

  int shared_mem_numel = 2 * N + 3;

  if (false)
    std::cout << "C,B,T,N = " << C << "," << B << "," << T << "," << N
              << ", images_per_thread_block = " << images_per_thread_block
              << ", grid_dim_y = " << grid_dim_y
              << "\n";

  TORCH_CHECK(THREADS_PER_BLOCK / images_per_thread_block >= T ||
              images_per_thread_block == 1,
              "Code error");

  TORCH_CHECK(N + 1 <= THREADS_PER_BLOCK,
              "Values of N this large are not supported.");

  dim3 gridDim(C, grid_dim_y, 1);

  // blockDim is scalar, just THREADS_PER_BLOCK.
  AT_DISPATCH_FLOATING_TYPES(input.scalar_type(), "mutual_information_kernel", ([&] {
        mutual_information_kernel<scalar_t><<<gridDim, THREADS_PER_BLOCK, sizeof(scalar_t) * shared_mem_numel, at::cuda::getCurrentCUDAStream()>>>(
              input.packed_accessor32<scalar_t, 3>(),
              params.packed_accessor32<scalar_t, 2>(),
              output.packed_accessor32<scalar_t, 3>(),
              images_per_thread_block);
      }));
  return output;
}



std::vector<torch::Tensor> mutual_information_backward_cuda(torch::Tensor input,
                                                        torch::Tensor params,
                                                        torch::Tensor output_grad) {
  TORCH_CHECK(input.dim() == 3, "input must be 3-dimensional");
  TORCH_CHECK(params.dim() == 2, "params must be 2-dimensional.");
  TORCH_CHECK(params.size(1) >= 3 &&
              ((params.size(1) - 1) & (params.size(1) - 2)) == 0,
              "params.size(1) has invalid value, must be a power of 2 plus 1.");
  TORCH_CHECK(params.size(0) == input.size(1),
              "params vs input channels mismatch");
  TORCH_CHECK(output_grad.dim() == 3 && output_grad.size(0) == input.size(0) &&
              output_grad.size(1) == input.size(1) &&
              output_grad.size(2) == input.size(2),
              "output_grad and input have mismatched dim.");

  TORCH_CHECK(input.device().is_cuda(), "Input must be a CUDA tensor");
  TORCH_CHECK(output_grad.device().is_cuda(), "output_grad must be a CUDA tensor");
  TORCH_CHECK(params.device().is_cuda(), "Params must be a CUDA tensor");

  const int B = input.size(0),
      C = input.size(1),
      T = input.size(2),
      N = params.size(1) - 1;

  TORCH_CHECK(N >= 4, "This backward code requires N >= 4");
  TORCH_CHECK(N <= 16, "This backward code currently requires N <= 16");
  TORCH_CHECK((N & (N-1)) == 0, "N must be a power of 2")

  auto scalar_t = input.scalar_type();
  auto opts = torch::TensorOptions().dtype(scalar_t).device(input.device());


  torch::Tensor input_grad = torch::empty({B, C, T}, opts);

  if (C * B * T == 0) {
    return std::vector<torch::Tensor>({input_grad,
            torch::empty({C, N + 1})});
  }

  int images_per_thread_block = 1;
  while (images_per_thread_block * 2 * T <= THREADS_PER_BLOCK &&
         images_per_thread_block * 2 * N <= THREADS_PER_BLOCK)
    images_per_thread_block *= 2;

  int grid_dim_y = 1;
  // If the number of channels is quite small (<128) we can launch more thread
  // groups, splitting on the batch index.
  while (C * grid_dim_y < 128)
    grid_dim_y *= 2;

  // B_reduced is the max number of thread-groups per channel that would have
  // any work to do.  If grid_dim_y is more than this, we reduce it to avoid
  // launching kernels with nothing to do.
  int B_reduced = (B + images_per_thread_block - 1) / images_per_thread_block;
  if (grid_dim_y > B_reduced)
    grid_dim_y = B_reduced;

  int shared_mem_numel = 2 * N + 3;



  if (false)
    std::cout << "C,B,T,N = " << C << "," << B << "," << T << "," << N
              << ", images_per_thread_block = " << images_per_thread_block
              << ", grid_dim_y = " << grid_dim_y
              << "\n";

  TORCH_CHECK(THREADS_PER_BLOCK / images_per_thread_block >= T ||
              images_per_thread_block == 1,
              "Code error");

  TORCH_CHECK(THREADS_PER_BLOCK / images_per_thread_block >= N);

  torch::Tensor params_grad = torch::zeros({grid_dim_y, C, N + 1}, opts);

  dim3 gridDim(C, grid_dim_y, 1);

  // blockDim is scalar, just THREADS_PER_BLOCK.
  AT_DISPATCH_FLOATING_TYPES(input.scalar_type(), "mutual_information_backward_kernel", ([&] {
        mutual_information_backward_kernel<scalar_t><<<gridDim, THREADS_PER_BLOCK, sizeof(scalar_t) * shared_mem_numel, at::cuda::getCurrentCUDAStream()>>>(
            input.packed_accessor32<scalar_t, 3>(),
            params.packed_accessor32<scalar_t, 2>(),
            output_grad.packed_accessor32<scalar_t, 3>(),
            input_grad.packed_accessor32<scalar_t, 3>(),
            params_grad.packed_accessor32<scalar_t, 3>(),
            images_per_thread_block);
      }));

  params_grad = at::sum(params_grad, {0});
  return std::vector<torch::Tensor>({input_grad, params_grad});
}