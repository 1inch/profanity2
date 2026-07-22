/* bench_mod_mul_pr49.cpp
 * ======================
 * Benchmark: mp_mod_mul with the old (pre-PR#49) vs new (optimized) mp_mul_mod_word_sub.
 *
 * Each work item performs a dependency-chained sequence of modular multiplications
 * x = x * y (mod p) using the real kernels compiled from profanity.cl + tests/harness.cl.
 * The chained data dependency prevents the compiler from eliminating work.
 *
 * Both variants are also cross-checked: starting from identical inputs, their final
 * outputs must be bit-exact identical.
 *
 * Note: absolute numbers on a CPU OpenCL implementation (e.g. PoCL) are not
 * representative of GPU throughput, but the relative old-vs-new comparison exercises
 * exactly the code path the PR optimizes.
 *
 * Build & run (see tests/Makefile):
 *   cd tests && make && ./bench_mod_mul_pr49.x64 [global_size] [iterations] [repetitions]
 */

#include <chrono>
#include <cstdio>
#include <random>
#include <vector>

#include "testutil.hpp"

struct BenchResult {
	double bestSeconds;
	std::vector<mp_number> output;
};

static BenchResult benchVariant(const ClSetup & s, const char * const kernelName,
	const std::vector<mp_number> & x, const std::vector<mp_number> & y,
	const uint32_t iterations, const int reps)
{
	const size_t count = x.size();
	cl_int err;
	cl_kernel kernel = clCreateKernel(s.program, kernelName, &err);
	clCheck(err, "clCreateKernel");

	cl_mem yBuf = clCreateBuffer(s.context, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, count * sizeof(mp_number), (void *)y.data(), &err);
	clCheck(err, "clCreateBuffer(y)");

	BenchResult result;
	result.bestSeconds = -1;
	result.output.resize(count);

	// reps timed runs + one warmup run (which also produces the output used
	// for the old-vs-new cross-check)
	for (int rep = 0; rep <= reps; ++rep) {
		cl_mem xBuf = clCreateBuffer(s.context, CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR, count * sizeof(mp_number), (void *)x.data(), &err);
		clCheck(err, "clCreateBuffer(x)");
		clCheck(clSetKernelArg(kernel, 0, sizeof(cl_mem), &xBuf), "clSetKernelArg(0)");
		clCheck(clSetKernelArg(kernel, 1, sizeof(cl_mem), &yBuf), "clSetKernelArg(1)");
		clCheck(clSetKernelArg(kernel, 2, sizeof(uint32_t), &iterations), "clSetKernelArg(2)");
		clCheck(clFinish(s.queue), "clFinish(pre)");

		const auto t0 = std::chrono::steady_clock::now();
		clCheck(clEnqueueNDRangeKernel(s.queue, kernel, 1, NULL, &count, NULL, 0, NULL, NULL), "clEnqueueNDRangeKernel");
		clCheck(clFinish(s.queue), "clFinish");
		const double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();

		if (rep == 0) {
			clCheck(clEnqueueReadBuffer(s.queue, xBuf, CL_TRUE, 0, count * sizeof(mp_number), result.output.data(), 0, NULL, NULL), "clEnqueueReadBuffer");
			clCheck(clFinish(s.queue), "clFinish(read)");
		} else if (result.bestSeconds < 0 || seconds < result.bestSeconds) {
			result.bestSeconds = seconds;
		}

		clReleaseMemObject(xBuf);
	}

	clReleaseMemObject(yBuf);
	clReleaseKernel(kernel);
	return result;
}

int main(int argc, char * * argv) {
	const size_t globalSize = argc > 1 ? (size_t)std::atol(argv[1]) : 4096;
	const uint32_t iterations = argc > 2 ? (uint32_t)std::atol(argv[2]) : 2000;
	const int reps = argc > 3 ? std::atoi(argv[3]) : 5;

	std::mt19937_64 rng(0xBEEF);
	std::vector<mp_number> x(globalSize), y(globalSize);
	for (size_t i = 0; i < globalSize; ++i) {
		for (int j = 0; j < MP_NWORDS; ++j) {
			x[i].d[j] = (uint32_t)rng();
			y[i].d[j] = (uint32_t)rng();
		}
	}

	const ClSetup s = clSetup();
	std::printf("Work items: %zu, chained mod-muls per item: %u, repetitions: %d (best time taken)\n",
		globalSize, iterations, reps);

	const BenchResult oldResult = benchVariant(s, "bench_mod_mul_old", x, y, iterations, reps);
	const BenchResult newResult = benchVariant(s, "bench_mod_mul_new", x, y, iterations, reps);

	size_t mismatches = 0;
	for (size_t i = 0; i < globalSize; ++i) {
		if (!mpEqual(oldResult.output[i], newResult.output[i])) {
			++mismatches;
		}
	}
	if (mismatches) {
		std::printf("CROSS-CHECK FAILED: outputs differ in %zu/%zu work items\n", mismatches, globalSize);
		return 1;
	}
	std::printf("Cross-check: outputs of old and new variants are bit-exact identical (%zu work items x %u chained mod-muls).\n\n",
		globalSize, iterations);

	const double totalMuls = (double)globalSize * iterations;
	std::printf("  old (master):  %9.2f ms  (%8.2f Mmul/s)\n", oldResult.bestSeconds * 1e3, totalMuls / oldResult.bestSeconds / 1e6);
	std::printf("  new (PR #49):  %9.2f ms  (%8.2f Mmul/s)\n", newResult.bestSeconds * 1e3, totalMuls / newResult.bestSeconds / 1e6);
	std::printf("  speedup: x%.3f (%+.1f%%)\n", oldResult.bestSeconds / newResult.bestSeconds,
		(oldResult.bestSeconds / newResult.bestSeconds - 1) * 100);
	return 0;
}
