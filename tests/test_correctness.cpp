/* test_correctness.cpp
 * ====================
 * Correctness and equivalence tests for the mp_mul_mod_word_sub optimization (PR #49).
 *
 * Runs the actual OpenCL kernels from profanity.cl (via tests/harness.cl wrappers) and checks:
 *
 * 1. mp_mul_mod_word_sub (new, optimized) vs mp_mul_mod_word_sub_old (pre-PR#49 master)
 *    produce bit-exact identical output.
 * 2. Both match an independent host-side big-integer reference:
 *        r' = (r - w * p - (withModHigher ? (p << 32) : 0)) mod 2^256
 *    where p is the secp256k1 prime.
 * 3. mp_mod_mul (which uses the new routine) vs mp_mod_mul_old are bit-exact identical
 *    (checked on all inputs, including out-of-domain ones >= p), and for in-domain
 *    inputs (field elements X, Y < p, which is how profanity uses it) the result is
 *    congruent to X * Y (mod p). (mp_mod_mul may return a value that is not fully
 *    reduced below p -- see "Cutting corners" in profanity.cl -- so congruence is the
 *    correct property to check.)
 *
 * Build & run (see tests/Makefile):
 *   cd tests && make && ./test_correctness.x64 [num_random_cases]
 */

#include <cstdio>
#include <random>
#include <vector>

#include "testutil.hpp"

static std::mt19937_64 g_rng(0xC0FFEE);

static uint32_t randomWord() {
	return (uint32_t)g_rng();
}

static mp_number randomNumber() {
	mp_number n;
	for (int i = 0; i < MP_NWORDS; ++i) {
		n.d[i] = randomWord();
	}
	return n;
}

/* ------------------------------------------------------------------------ */
/* mp_mul_mod_word_sub                                                       */
/* ------------------------------------------------------------------------ */

struct WordSubCase {
	mp_number r;
	uint32_t w;
	uint32_t withModHigher;
};

static std::vector<WordSubCase> genWordSubCases(const size_t numRandom) {
	const mp_number zero = { { 0 } };
	const mp_number allOnes = { { 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff } };
	mp_number pPlusOne = g_p; pPlusOne.d[0] += 1;
	mp_number pMinusOne = g_p; pMinusOne.d[0] -= 1;
	const mp_number one = { { 1 } };
	const mp_number highBit = { { 0, 0, 0, 0, 0, 0, 0, 0x80000000 } };
	const mp_number pattern = { { 0xffffffff, 0, 0xffffffff, 0, 0xffffffff, 0, 0xffffffff, 0 } };

	const mp_number edgeR[] = { zero, one, allOnes, g_p, pPlusOne, pMinusOne, highBit, pattern };
	const uint32_t edgeW[] = { 0, 1, 2, 976, 977, 978, 0x3D0, 0x3D1, 0x3D2,
	                           0x7FFFFFFF, 0x80000000, 0xFFFFFC2E, 0xFFFFFC2F, 0xFFFFFC30,
	                           0xFFFFFFFE, 0xFFFFFFFF };

	std::vector<WordSubCase> cases;
	for (const mp_number & r : edgeR) {
		for (const uint32_t w : edgeW) {
			for (uint32_t wmh = 0; wmh <= 1; ++wmh) {
				cases.push_back({ r, w, wmh });
			}
		}
	}
	for (size_t i = 0; i < numRandom; ++i) {
		cases.push_back({ randomNumber(), randomWord(), (uint32_t)(g_rng() & 1) });
	}
	return cases;
}

// Runs k_mul_mod_word_sub_{old,new} over all cases in one kernel invocation
static std::vector<mp_number> runWordSubKernel(const ClSetup & s, const char * const kernelName, const std::vector<WordSubCase> & cases) {
	const size_t count = cases.size();
	std::vector<mp_number> r(count);
	std::vector<uint32_t> w(count), wmh(count);
	for (size_t i = 0; i < count; ++i) {
		r[i] = cases[i].r;
		w[i] = cases[i].w;
		wmh[i] = cases[i].withModHigher;
	}

	cl_int err;
	cl_mem rBuf = clCreateBuffer(s.context, CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR, count * sizeof(mp_number), r.data(), &err);
	clCheck(err, "clCreateBuffer(r)");
	cl_mem wBuf = clCreateBuffer(s.context, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, count * sizeof(uint32_t), w.data(), &err);
	clCheck(err, "clCreateBuffer(w)");
	cl_mem mBuf = clCreateBuffer(s.context, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, count * sizeof(uint32_t), wmh.data(), &err);
	clCheck(err, "clCreateBuffer(wmh)");

	cl_kernel kernel = clCreateKernel(s.program, kernelName, &err);
	clCheck(err, "clCreateKernel");
	clCheck(clSetKernelArg(kernel, 0, sizeof(cl_mem), &rBuf), "clSetKernelArg(0)");
	clCheck(clSetKernelArg(kernel, 1, sizeof(cl_mem), &wBuf), "clSetKernelArg(1)");
	clCheck(clSetKernelArg(kernel, 2, sizeof(cl_mem), &mBuf), "clSetKernelArg(2)");

	clCheck(clEnqueueNDRangeKernel(s.queue, kernel, 1, NULL, &count, NULL, 0, NULL, NULL), "clEnqueueNDRangeKernel");
	clCheck(clEnqueueReadBuffer(s.queue, rBuf, CL_TRUE, 0, count * sizeof(mp_number), r.data(), 0, NULL, NULL), "clEnqueueReadBuffer");
	clCheck(clFinish(s.queue), "clFinish");

	clReleaseKernel(kernel);
	clReleaseMemObject(rBuf);
	clReleaseMemObject(wBuf);
	clReleaseMemObject(mBuf);
	return r;
}

static size_t testMulModWordSub(const ClSetup & s, const size_t numRandom) {
	const std::vector<WordSubCase> cases = genWordSubCases(numRandom);
	const std::vector<mp_number> outNew = runWordSubKernel(s, "k_mul_mod_word_sub_new", cases);
	const std::vector<mp_number> outOld = runWordSubKernel(s, "k_mul_mod_word_sub_old", cases);

	size_t failures = 0;
	for (size_t i = 0; i < cases.size(); ++i) {
		if (!mpEqual(outNew[i], outOld[i])) {
			if (++failures <= 5) {
				std::printf("  EQUIVALENCE MISMATCH case %zu: r=%s w=%#010x wmh=%u\n",
					i, mpToHex(cases[i].r).c_str(), cases[i].w, cases[i].withModHigher);
			}
			continue;
		}
		const mp_number expect = refMulModWordSub(cases[i].r, cases[i].w, cases[i].withModHigher != 0);
		if (!mpEqual(outNew[i], expect)) {
			if (++failures <= 5) {
				std::printf("  REFERENCE MISMATCH case %zu: r=%s w=%#010x wmh=%u\n    got      %s\n    expected %s\n",
					i, mpToHex(cases[i].r).c_str(), cases[i].w, cases[i].withModHigher,
					mpToHex(outNew[i]).c_str(), mpToHex(expect).c_str());
			}
		}
	}

	std::printf("mp_mul_mod_word_sub: %zu cases (old-vs-new bit-exact + big-int reference): %s\n",
		cases.size(), failures == 0 ? "OK" : "FAILED");
	return failures;
}

/* ------------------------------------------------------------------------ */
/* mp_mod_mul                                                                */
/* ------------------------------------------------------------------------ */

struct ModMulCase {
	mp_number x;
	mp_number y;
};

static std::vector<ModMulCase> genModMulCases(const size_t numRandom) {
	const mp_number zero = { { 0 } };
	const mp_number one = { { 1 } };
	const mp_number two = { { 2 } };
	const mp_number allOnes = { { 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff } };
	mp_number pPlusOne = g_p; pPlusOne.d[0] += 1;
	mp_number pMinusOne = g_p; pMinusOne.d[0] -= 1;
	const mp_number highBit = { { 0, 0, 0, 0, 0, 0, 0, 0x80000000 } };
	const mp_number w977 = { { 977 } };
	const mp_number pmod = { { 0x000003D1, 1 } }; // 2^32 + 977

	// Out-of-domain values (>= p) are included: mp_mod_mul makes no congruence
	// guarantee for them (a pre-existing property of the algorithm, see "Cutting
	// corners"), but old and new must still be bit-exact identical on them.
	const mp_number edge[] = { zero, one, two, pMinusOne, g_p, pPlusOne, allOnes, highBit, w977, pmod };

	std::vector<ModMulCase> cases;
	for (const mp_number & x : edge) {
		for (const mp_number & y : edge) {
			cases.push_back({ x, y });
		}
	}
	for (size_t i = 0; i < numRandom; ++i) {
		cases.push_back({ randomNumber(), randomNumber() });
	}
	return cases;
}

static std::vector<mp_number> runModMulKernel(const ClSetup & s, const char * const kernelName, const std::vector<ModMulCase> & cases) {
	const size_t count = cases.size();
	std::vector<mp_number> x(count), y(count), out(count);
	for (size_t i = 0; i < count; ++i) {
		x[i] = cases[i].x;
		y[i] = cases[i].y;
	}

	cl_int err;
	cl_mem xBuf = clCreateBuffer(s.context, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, count * sizeof(mp_number), x.data(), &err);
	clCheck(err, "clCreateBuffer(x)");
	cl_mem yBuf = clCreateBuffer(s.context, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, count * sizeof(mp_number), y.data(), &err);
	clCheck(err, "clCreateBuffer(y)");
	cl_mem rBuf = clCreateBuffer(s.context, CL_MEM_WRITE_ONLY, count * sizeof(mp_number), NULL, &err);
	clCheck(err, "clCreateBuffer(out)");

	cl_kernel kernel = clCreateKernel(s.program, kernelName, &err);
	clCheck(err, "clCreateKernel");
	clCheck(clSetKernelArg(kernel, 0, sizeof(cl_mem), &xBuf), "clSetKernelArg(0)");
	clCheck(clSetKernelArg(kernel, 1, sizeof(cl_mem), &yBuf), "clSetKernelArg(1)");
	clCheck(clSetKernelArg(kernel, 2, sizeof(cl_mem), &rBuf), "clSetKernelArg(2)");

	clCheck(clEnqueueNDRangeKernel(s.queue, kernel, 1, NULL, &count, NULL, 0, NULL, NULL), "clEnqueueNDRangeKernel");
	clCheck(clEnqueueReadBuffer(s.queue, rBuf, CL_TRUE, 0, count * sizeof(mp_number), out.data(), 0, NULL, NULL), "clEnqueueReadBuffer");
	clCheck(clFinish(s.queue), "clFinish");

	clReleaseKernel(kernel);
	clReleaseMemObject(xBuf);
	clReleaseMemObject(yBuf);
	clReleaseMemObject(rBuf);
	return out;
}

static size_t testModMul(const ClSetup & s, const size_t numRandom) {
	const std::vector<ModMulCase> cases = genModMulCases(numRandom);
	const std::vector<mp_number> outNew = runModMulKernel(s, "k_mod_mul_new", cases);
	const std::vector<mp_number> outOld = runModMulKernel(s, "k_mod_mul_old", cases);

	size_t failures = 0;
	size_t congruenceChecked = 0;
	for (size_t i = 0; i < cases.size(); ++i) {
		if (!mpEqual(outNew[i], outOld[i])) {
			if (++failures <= 5) {
				std::printf("  EQUIVALENCE MISMATCH case %zu: x=%s y=%s\n",
					i, mpToHex(cases[i].x).c_str(), mpToHex(cases[i].y).c_str());
			}
			continue;
		}

		// Congruence is only guaranteed for in-domain inputs (field elements < p)
		if (!mpGte(cases[i].x, g_p) && !mpGte(cases[i].y, g_p)) {
			++congruenceChecked;
			const mp_number got = refModP256(outNew[i]);
			const mp_number expect = refMulModP(cases[i].x, cases[i].y);
			if (!mpEqual(got, expect)) {
				if (++failures <= 5) {
					std::printf("  CONGRUENCE MISMATCH case %zu: x=%s y=%s\n    got%%p    %s\n    x*y%%p    %s\n",
						i, mpToHex(cases[i].x).c_str(), mpToHex(cases[i].y).c_str(),
						mpToHex(got).c_str(), mpToHex(expect).c_str());
				}
			}
		}
	}

	std::printf("mp_mod_mul: %zu cases old-vs-new bit-exact, %zu in-domain cases congruent mod p: %s\n",
		cases.size(), congruenceChecked, failures == 0 ? "OK" : "FAILED");
	return failures;
}

int main(int argc, char * * argv) {
	const size_t numRandom = argc > 1 ? (size_t)std::atol(argv[1]) : 100000;

	const ClSetup s = clSetup();

	size_t failures = 0;
	failures += testMulModWordSub(s, numRandom);
	failures += testModMul(s, numRandom / 10 > 1000 ? numRandom / 10 : 1000);

	if (failures) {
		std::printf("FAILED: %zu total failures\n", failures);
		return 1;
	}
	std::printf("All tests passed.\n");
	return 0;
}
